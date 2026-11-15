--- Static diagnostics for Django ORM paths.
---
--- Walks the syntax tree of a Python buffer and validates the field paths
--- passed to QuerySet methods against the runtime schema. The checks are
--- intentionally conservative: anything the resolver cannot judge is skipped
--- instead of guessed.
local M = {}

local path = require("django.completions.core.path")
local ts_context = require("django.completions.core.ts_context")
local ModelData = require("django.completions.core.model_data")
local config = require("django.config")

M.NAMESPACE = vim.api.nvim_create_namespace("django_orm_diagnostics")

M.SEVERITY = vim.diagnostic.severity.WARN

--- LSP clients that already report ORM errors
M.EXTERNAL_CLIENTS = { pogo = true }

--- Source and code prefix Pogo uses for its ORM diagnostics
M.POGO_SOURCE = "pogo"
M.POGO_CODE_PREFIX = "django-orm."

--- Supported arbitration policies (see config.diagnostics.pogo)
M.POLICIES = { auto = true, prefer = true, ignore = true }

--- Last seen external diagnostic signature per buffer
M.external_signatures = {}

--- Diagnostic codes, aligned with the vocabulary Pogo publishes so that a
--- single `vim.diagnostic.config` filter and code based dedupe cover both.
M.CODES = {
	unknown_segment = "django-orm.unknown-path-segment",
	non_relation_traversal = "django-orm.nonrelation-traversal",
	invalid_lookup = "django-orm.invalid-lookup-or-transform",
	invalid_projection = "django-orm.invalid-projection-path",
	invalid_select_related = "django-orm.invalid-select-related-target",
}

--- Relation types accepted by select_related()
M.SELECT_RELATIONS = {
	ForeignKey = true,
	OneToOneField = true,
	OneToOneRel = true,
}

--- Methods whose arguments are ORM paths
--- paths: "keyword" | "string"
--- lookups: whether a lookup segment is allowed (only the filter family is)
--- relations: restrict the terminal field to a relation type
--- projection: the method projects columns (values/only/...), so a lookup is
---             reported as an invalid projection path
--- skip: keyword arguments that are not paths
M.METHODS = {
	filter = { paths = "keyword", lookups = true },
	exclude = { paths = "keyword", lookups = true },
	get = { paths = "keyword", lookups = true },
	get_or_create = { paths = "keyword", lookups = true, skip = { defaults = true } },
	update_or_create = { paths = "keyword", lookups = true, skip = { defaults = true } },
	create = { paths = "keyword", lookups = false },
	update = { paths = "keyword", lookups = false },
	values = { paths = "string", lookups = false, projection = true },
	values_list = { paths = "string", lookups = false, projection = true },
	only = { paths = "string", lookups = false, projection = true },
	defer = { paths = "string", lookups = false, projection = true },
	order_by = { paths = "string", lookups = false },
	latest = { paths = "string", lookups = false },
	earliest = { paths = "string", lookups = false },
	select_related = { paths = "string", lookups = false, relations = "select" },
	prefetch_related = { paths = "string", lookups = false, relations = "any" },
}

--- Matches every method call with an attribute target
M.CALL_QUERY = [[
(call
  function: (attribute
    attribute: (identifier) @method)
  arguments: (argument_list) @arguments) @call
]]

--- Timers used to debounce BufWritePost
local pending = {}

--- Register the autocommands
function M.setup()
	local group = vim.api.nvim_create_augroup("django_orm_diagnostics", { clear = true })

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*.py",
		callback = function(args)
			M.schedule(args.buf)
		end,
	})

	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		callback = function(args)
			pending[args.buf] = nil
			M.external_signatures[args.buf] = nil
			vim.diagnostic.reset(M.NAMESPACE, args.buf)
		end,
	})

	-- Pogo publishes diagnostics asynchronously: reconcile again when its ORM
	-- diagnostics change so duplicates are suppressed (and restored when they
	-- disappear). The signature guard keeps our own updates from looping.
	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = group,
		callback = function(args)
			if M.policy() ~= "auto" then
				return
			end

			local bufnr = tonumber(args.buf)
			if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end

			local signature = M.__external_signature(bufnr)
			if signature ~= (M.external_signatures[bufnr] or "") then
				M.external_signatures[bufnr] = signature
				M.schedule(bufnr)
			end
		end,
	})

	-- A schema refresh can fix or reveal errors, so re-check the buffers
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "DjangoDataRefreshed",
		callback = function()
			M.refresh()
		end,
	})
end

--- Schedule a diagnostic run for a buffer
--- @param bufnr number
function M.schedule(bufnr)
	if not M.enabled() then
		return
	end

	pending[bufnr] = (pending[bufnr] or 0) + 1
	local generation = pending[bufnr]

	vim.defer_fn(function()
		if pending[bufnr] ~= generation then
			return
		end
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		M.publish(bufnr)
	end, config.current.diagnostics.debounce_ms)
end

--- Re-run diagnostics for every loaded Python buffer
function M.refresh()
	if not M.enabled() then
		return
	end

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "python" then
			M.publish(bufnr)
		end
	end
end

--- Whether diagnostics are enabled
--- @return boolean
function M.enabled()
	local diagnostics = config.current.diagnostics
	return diagnostics ~= nil and diagnostics.enabled == true
end

--- Publish diagnostics for a buffer
--- @param bufnr number
function M.publish(bufnr)
	if not M.enabled() or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end

	if vim.bo[bufnr].filetype ~= "python" then
		return
	end

	local policy = M.policy()

	if policy == "prefer" and M.is_covered_externally(bufnr) then
		vim.diagnostic.reset(M.NAMESPACE, bufnr)
		return
	end

	local diagnostics = M.collect(bufnr)

	if policy == "auto" then
		diagnostics = M.__dedupe(diagnostics, M.__external_diagnostics(bufnr))
	end

	M.external_signatures[bufnr] = M.__external_signature(bufnr)
	vim.diagnostic.set(M.NAMESPACE, bufnr, diagnostics)
end

--- Arbitration policy for ORM diagnostics
--- @return string "auto"|"prefer"|"ignore"
function M.policy()
	local diagnostics = config.current.diagnostics
	local policy = diagnostics and diagnostics.pogo or nil

	if M.POLICIES[policy] then
		return policy
	end

	return "auto"
end

--- Whether a diagnostic was published by Pogo for an ORM path
--- @param diagnostic vim.Diagnostic
--- @return boolean
function M.__is_external(diagnostic)
	if not diagnostic or diagnostic.source ~= M.POGO_SOURCE then
		return false
	end

	local code = diagnostic.code
	if type(code) ~= "string" then
		return false
	end

	return code:sub(1, #M.POGO_CODE_PREFIX) == M.POGO_CODE_PREFIX
end

--- Collect the Pogo ORM diagnostics of a buffer
--- @param bufnr number
--- @return vim.Diagnostic[]
function M.__external_diagnostics(bufnr)
	local external = {}

	for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
		if M.__is_external(diagnostic) then
			table.insert(external, diagnostic)
		end
	end

	return external
end

--- Stable signature of the external diagnostics of a buffer
--- @param bufnr number
--- @return string
function M.__external_signature(bufnr)
	local parts = {}

	for _, diagnostic in ipairs(M.__external_diagnostics(bufnr)) do
		table.insert(
			parts,
			string.format(
				"%s:%d:%d:%d:%d",
				tostring(diagnostic.code),
				diagnostic.lnum or 0,
				diagnostic.col or 0,
				diagnostic.end_lnum or diagnostic.lnum or 0,
				diagnostic.end_col or diagnostic.col or 0
			)
		)
	end

	table.sort(parts)

	return table.concat(parts, "|")
end

--- Drop our diagnostics that Pogo already reports
--- @param diagnostics vim.Diagnostic[]
--- @param external vim.Diagnostic[]
--- @return vim.Diagnostic[]
function M.__dedupe(diagnostics, external)
	if not external or #external == 0 then
		return diagnostics
	end

	local kept = {}

	for _, diagnostic in ipairs(diagnostics) do
		if not M.__duplicates(diagnostic, external) then
			table.insert(kept, diagnostic)
		end
	end

	return kept
end

--- Whether an external diagnostic covers the same issue as ours
--- @param diagnostic vim.Diagnostic
--- @param external vim.Diagnostic[]
--- @return boolean
function M.__duplicates(diagnostic, external)
	for _, other in ipairs(external) do
		if diagnostic.code == other.code and M.__overlaps(diagnostic, other) then
			return true
		end
	end

	return false
end

--- Whether two diagnostics underline overlapping text on the same line
--- @param left vim.Diagnostic
--- @param right vim.Diagnostic
--- @return boolean
function M.__overlaps(left, right)
	if (left.lnum or 0) ~= (right.lnum or 0) then
		return false
	end

	local left_start = left.col or 0
	local right_start = right.col or 0
	local left_end = math.max(left.end_col or left_start, left_start + 1)
	local right_end = math.max(right.end_col or right_start, right_start + 1)

	return left_start < right_end and right_start < left_end
end

--- Whether another tool already reports ORM errors for the buffer
--- @param bufnr number
--- @return boolean
function M.is_covered_externally(bufnr)
	return M.__covered_by(vim.lsp.get_clients({ bufnr = bufnr }))
end

--- Check a client list for an ORM aware language server
--- @param clients table[]|nil
--- @return boolean
function M.__covered_by(clients)
	for _, client in ipairs(clients or {}) do
		if M.EXTERNAL_CLIENTS[client.name] then
			return true
		end
	end

	return false
end

--- Collect diagnostics for a buffer
--- @param bufnr number
--- @return vim.Diagnostic[]
function M.collect(bufnr)
	local model_data = ModelData.peek()
	if not model_data then
		return {}
	end

	local root = ts_context.__root(bufnr)
	if not root then
		return {}
	end

	local ok, query = pcall(vim.treesitter.query.parse, "python", M.CALL_QUERY)
	if not ok then
		return {}
	end

	local diagnostics = {}

	for _, match in query:iter_matches(root, bufnr, 0, -1) do
		local call = M.__capture(query, match, "call")
		local arguments = M.__capture(query, match, "arguments")
		local method_node = M.__capture(query, match, "method")

		if call and arguments and method_node then
			local method = ts_context.__text(method_node, bufnr)
			vim.list_extend(diagnostics, M.__check_call(bufnr, call, arguments, method, model_data))
		end
	end

	return diagnostics
end

--- Validate the arguments of a single call
--- @param bufnr number
--- @param call TSNode
--- @param arguments TSNode
--- @param method string
--- @param model_data ModelData
--- @return vim.Diagnostic[]
function M.__check_call(bufnr, call, arguments, method, model_data)
	local spec = M.METHODS[method]
	if not spec then
		return {}
	end

	local model_name = M.__model_of(bufnr, call, model_data)
	if not model_name then
		return {}
	end

	return M.__check_arguments(bufnr, arguments, spec, model_name, model_data)
end

--- Validate the arguments of a call list against a known model
--- @param bufnr number
--- @param arguments TSNode
--- @param spec table Method specification
--- @param model_name string
--- @param model_data ModelData
--- @return vim.Diagnostic[]
function M.__check_arguments(bufnr, arguments, spec, model_name, model_data)
	local diagnostics = {}

	for _, argument in ipairs(arguments:named_children()) do
		local argument_type = argument:type()

		if spec.paths == "keyword" and argument_type == "keyword_argument" then
			vim.list_extend(diagnostics, M.__check_keyword(bufnr, argument, spec, model_name, model_data))
		elseif spec.paths == "string" and argument_type == "string" then
			vim.list_extend(diagnostics, M.__check_string(bufnr, argument, spec, model_name, model_data))
		elseif spec.paths == "keyword" and argument_type ~= "keyword_argument" then
			-- filter(Q(title="x") | Q(status="y")): the keywords inside Q objects
			-- are paths of the same model
			vim.list_extend(diagnostics, M.__check_q_objects(bufnr, argument, spec, model_name, model_data))
		end
	end

	return diagnostics
end

--- Validate the keywords of every Q() object inside a node
--- @param bufnr number
--- @param node TSNode
--- @param spec table Method specification
--- @param model_name string
--- @param model_data ModelData
--- @return vim.Diagnostic[]
function M.__check_q_objects(bufnr, node, spec, model_name, model_data)
	local diagnostics = {}

	if node:type() == "call" and M.__is_q_call(bufnr, node) then
		local inner = node:field("arguments")[1]
		if inner then
			vim.list_extend(diagnostics, M.__check_arguments(bufnr, inner, spec, model_name, model_data))
		end

		return diagnostics
	end

	for _, child in ipairs(node:named_children()) do
		vim.list_extend(diagnostics, M.__check_q_objects(bufnr, child, spec, model_name, model_data))
	end

	return diagnostics
end

--- Check whether a call is a Q() lookup
--- @param bufnr number
--- @param call TSNode
--- @return boolean
function M.__is_q_call(bufnr, call)
	local fn = call:field("function")[1]
	if not fn then
		return false
	end

	local chain = ts_context.__flatten(fn, bufnr)

	return chain[#chain] == "Q"
end

--- Validate a keyword argument path
--- @param bufnr number
--- @param argument TSNode
--- @param spec table Method specification
--- @param model_name string
--- @param model_data ModelData
--- @return vim.Diagnostic[]
function M.__check_keyword(bufnr, argument, spec, model_name, model_data)
	local name = argument:field("name")[1]
	if not name then
		return {}
	end

	local text = ts_context.__text(name, bufnr)
	if spec.skip and spec.skip[text] then
		return {}
	end

	local row, col = name:start()

	return M.__validate(text, row, col, spec, model_name, model_data)
end

--- Validate a string argument path
--- @param bufnr number
--- @param argument TSNode
--- @param spec table Method specification
--- @param model_name string
--- @param model_data ModelData
--- @return vim.Diagnostic[]
function M.__check_string(bufnr, argument, spec, model_name, model_data)
	local text = ts_context.__text(argument, bufnr)
	local content, offset = M.__string_content(text)

	if not content then
		return {}
	end

	-- order_by() accepts a "-" prefix for descending order
	local descending = content:sub(1, 1) == "-"
	local value = descending and content:sub(2) or content

	if value == "" or value:find("%s") then
		return {}
	end

	if descending then
		offset = offset + 1
	end

	local row, col = argument:start()

	return M.__validate(value, row, col + offset, spec, model_name, model_data)
end

--- Extract the content of a plain string literal
--- @param text string
--- @return string|nil content
--- @return number offset Byte offset of the content inside the literal
function M.__string_content(text)
	local prefix = text:match("^(%a*)[\"']")
	if not prefix then
		return nil, 0
	end

	-- f-strings and other interpolated literals are not static
	if prefix:lower():find("f") then
		return nil, 0
	end

	local body = text:sub(#prefix + 1)
	local triple = body:sub(1, 3)

	if triple == '"""' or triple == "'''" then
		return body:sub(4, -4), #prefix + 3
	end

	return body:sub(2, -2), #prefix + 1
end

--- Validate a single path and build diagnostics for it
--- @param text string Path as written by the user
--- @param row number
--- @param col number Byte column the path starts at
--- @param spec table Method specification
--- @param model_name string
--- @param model_data ModelData
--- @return vim.Diagnostic[]
function M.__validate(text, row, col, spec, model_name, model_data)
	local result = path.validate(model_name, text, model_data)

	if result.ok then
		return M.__check_resolved(text, row, col, spec, result)
	end

	local error = result.error
	if not error or error.kind == "unknown-model" then
		return {}
	end

	local start_col, end_col = M.__segment_range(text, error.index, col)

	local code = M.CODES.unknown_segment
	local message = error.message

	if error.kind == "invalid-lookup" then
		local owner = result.field_model
		local segment = error.segment

		if owner and model_data:get_field(owner, segment) then
			code = M.CODES.non_relation_traversal
			message = string.format(
				"Cannot traverse from '%s' (not a relation) to '%s'",
				tostring(result.field_name),
				segment
			)
		else
			code = M.CODES.invalid_lookup
		end
	end

	return {
		M.__diagnostic(row, start_col, end_col, message, code),
	}
end

--- Validate a path that resolved successfully
--- @param text string
--- @param row number
--- @param col number
--- @param spec table
--- @param result DjangoPathResult
--- @return vim.Diagnostic[]
function M.__check_resolved(text, row, col, spec, result)
	if result.lookup and spec.lookups == false then
		local start_col, end_col = M.__segment_range(text, #path.split(text), col)
		local code = spec.projection and M.CODES.invalid_projection or M.CODES.invalid_lookup

		return {
			M.__diagnostic(
				row,
				start_col,
				end_col,
				string.format("Lookups are not supported by this method ('%s')", result.lookup),
				code
			),
		}
	end

	if spec.relations and result.field then
		local field = result.field

		if spec.relations == "any" and not field.related_model then
			local start_col, end_col = M.__segment_range(text, #path.split(text), col)
			return {
				M.__diagnostic(
					row,
					start_col,
					end_col,
					string.format("'%s' is not a relation and cannot be prefetched", text),
					M.CODES.non_relation_traversal
				),
			}
		end

		if spec.relations == "select" and not (field.related_model and M.SELECT_RELATIONS[field.type]) then
			local start_col, end_col = M.__segment_range(text, #path.split(text), col)
			return {
				M.__diagnostic(
					row,
					start_col,
					end_col,
					string.format("select_related() cannot follow '%s' (%s)", text, field.type),
					M.CODES.invalid_select_related
				),
			}
		end
	end

	return {}
end

--- Resolve the model a call chain is rooted at
--- @param bufnr number
--- @param call TSNode
--- @param model_data ModelData
--- @return string|nil
function M.__model_of(bufnr, call, model_data)
	local fn = call:field("function")[1]
	local chain = ts_context.__flatten(fn, bufnr)
	local model_name = ts_context.receiver_model(bufnr, chain, ts_context.__scope(call), model_data)

	if not model_name or not model_data:get_model(model_name) then
		return nil
	end

	return model_name
end

--- Build a diagnostic
--- @param row number
--- @param start_col number
--- @param end_col number
--- @param message string
--- @param code string
--- @return vim.Diagnostic
function M.__diagnostic(row, start_col, end_col, message, code)
	return {
		lnum = row,
		col = start_col,
		end_lnum = row,
		end_col = end_col,
		severity = M.SEVERITY,
		source = "django.nvim",
		code = code,
		message = message,
	}
end

--- Byte range of a path segment
--- @param text string
--- @param index number Segment index (1-based)
--- @param base_col number Byte column the path starts at
--- @return number start_col
--- @return number end_col
function M.__segment_range(text, index, base_col)
	local offset = 0

	for position, segment in ipairs(path.split(text)) do
		if position == index then
			return base_col + offset, base_col + offset + #segment
		end
		offset = offset + #segment + 2
	end

	return base_col, base_col + #text
end

--- Read a capture out of an iter_matches result
--- @param query vim.treesitter.Query
--- @param match table
--- @param name string
--- @return TSNode|nil
function M.__capture(query, match, name)
	for id, nodes in pairs(match) do
		if query.captures[id] == name then
			return type(nodes) == "table" and nodes[1] or nodes
		end
	end

	return nil
end

return M

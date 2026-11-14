--- Treesitter based ORM context inference.
---
--- Resolves which model, which QuerySet method and which path prefix the
--- cursor sits in, without talking to a language server.
---
--- The parser is the primary engine: an incomplete call such as
--- `Post.objects.filter(tit` parses into an ERROR node, so the resolver
--- never relies on a `call` node being present.
local M = {}

local imports = require("django.completions.core.imports")

---@class DjangoOrmContext
---@field model_name string Model the ORM path is rooted at
---@field method string QuerySet method ("filter", "select_related", ...)
---@field prefix string Path typed so far ("author__username__ie")
---@field arg_kind "keyword"|"positional"|"string"|"bare"|"none"
---@field chain string[] Flattened receiver chain
---@field scope TSNode|nil Enclosing function or class

--- Get the parsed root node of a buffer
--- The tree has to be parsed explicitly: vim.treesitter.get_node() only looks
--- at already parsed trees and never triggers a parse on its own.
--- @param bufnr number
--- @return TSNode|nil
function M.__root(bufnr)
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
	if not ok or not parser then
		return nil
	end

	local trees = parser:parse()
	if not trees or not trees[1] then
		return nil
	end

	return trees[1]:root()
end

--- Get the text of a node
--- @param node TSNode|nil
--- @param bufnr number
--- @return string
function M.__text(node, bufnr)
	if not node then
		return ""
	end
	return vim.treesitter.get_node_text(node, bufnr) or ""
end

--- Get a line of a buffer
--- @param bufnr number
--- @param row number
--- @return string
function M.__line(bufnr, row)
	local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
	return lines[1] or ""
end

--- Get the character at a byte position
--- @param bufnr number
--- @param row number
--- @param col number
--- @return string|nil
function M.__char(bufnr, row, col)
	local line = M.__line(bufnr, row)
	if col < 0 or col >= #line then
		return nil
	end
	return line:sub(col + 1, col + 1)
end

--- Get the text between two positions
--- @param bufnr number
--- @param start_row number
--- @param start_col number
--- @param end_row number
--- @param end_col number
--- @return string
function M.__text_between(bufnr, start_row, start_col, end_row, end_col)
	local parts = {}

	for row = start_row, end_row do
		local line = M.__line(bufnr, row)
		local from = row == start_row and start_col or 0
		local to = row == end_row and end_col or #line
		table.insert(parts, line:sub(from + 1, to))
	end

	return table.concat(parts, "\n")
end

--- Find the nearest ancestor of a given type
--- @param node TSNode|nil
--- @param node_type string
--- @return TSNode|nil
function M.__ancestor(node, node_type)
	while node do
		if node:type() == node_type then
			return node
		end
		node = node:parent()
	end

	return nil
end

--- Find the named node right before a node
--- @param node TSNode
--- @return TSNode|nil
function M.__sibling_before(node)
	local sibling = node:prev_sibling()

	while sibling and not sibling:named() do
		sibling = sibling:prev_sibling()
	end

	return sibling
end

--- Get the statement the cursor sits in
--- @param node TSNode|nil
--- @return TSNode|nil
function M.__statement(node)
	if not node then
		return nil
	end

	while node:parent() and node:parent():type() ~= "module" do
		node = node:parent()
	end

	return node
end

--- Find the named node at a position
--- @param bufnr number
--- @param row number
--- @param col number
--- @return TSNode|nil
function M.__node_at(bufnr, row, col)
	local root = M.__root(bufnr)
	if not root then
		return nil
	end

	local line = M.__line(bufnr, row)
	local position = math.max(0, math.min(col, #line))

	for _, probe in ipairs({ position, position - 1 }) do
		if probe >= 0 then
			local node = root:named_descendant_for_range(row, probe, row, probe)
			if node and node:type() ~= "module" then
				return node
			end
		end
	end

	return root
end

--- Flatten an attribute/call chain into names
--- @param node TSNode|nil
--- @param bufnr number
--- @return string[]
function M.__flatten(node, bufnr)
	if not node then
		return {}
	end

	local node_type = node:type()

	if node_type == "attribute" then
		local object = node:field("object")[1]
		local attribute = node:field("attribute")[1]
		local chain = M.__flatten(object, bufnr)
		table.insert(chain, M.__text(attribute, bufnr))
		return chain
	end

	if node_type == "call" then
		local fn = node:field("function")[1]
		local chain = M.__flatten(fn, bufnr)
		table.insert(chain, "()")
		return chain
	end

	if node_type == "identifier" then
		return { M.__text(node, bufnr) }
	end

	return {}
end

--- Check whether a node ends at or before a position
--- @param node TSNode
--- @param row number
--- @param col number
--- @return boolean
function M.__ends_before(node, row, col)
	local end_row, end_col = node:end_()
	return end_row < row or (end_row == row and end_col <= col)
end

--- Pick the attribute that ends closest to the cursor
--- @param current TSNode|nil
--- @param candidate TSNode
--- @return TSNode
function M.__closest(current, candidate)
	if not current then
		return candidate
	end

	local current_row, current_col = current:end_()
	local candidate_row, candidate_col = candidate:end_()

	if candidate_row ~= current_row then
		return candidate_row > current_row and candidate or current
	end

	return candidate_col > current_col and candidate or current
end

--- Find the receiver chain of the call the cursor is inside
--- The chain is the attribute ending closest to the cursor whose opening
--- parenthesis is still unbalanced at the cursor.
--- @param anchor TSNode|nil
--- @param row number
--- @param col number
--- @param bufnr number
--- @return string[] chain, string|nil method, TSNode|nil attribute
function M.__find_chain(anchor, row, col, bufnr)
	local statement = M.__statement(anchor)
	if not statement then
		return {}, nil, nil
	end

	local best = nil

	local function visit(node)
		if node:type() == "attribute" and M.__ends_before(node, row, col) then
			best = M.__closest(best, node)
		end

		for _, child in ipairs(node:named_children()) do
			visit(child)
		end
	end

	if statement:type() == "module" then
		for _, child in ipairs(statement:named_children()) do
			visit(child)
		end
	else
		visit(statement)
	end

	if not best or not M.__inside_call(best, row, col, bufnr) then
		return {}, nil, nil
	end

	local chain = M.__flatten(best, bufnr)

	while #chain > 0 and chain[#chain] == "()" do
		table.remove(chain)
	end

	local method = chain[#chain]

	return chain, method, best
end

--- Check whether the cursor is inside the argument list of a call target
--- @param node TSNode
--- @param row number
--- @param col number
--- @param bufnr number
--- @return boolean
function M.__inside_call(node, row, col, bufnr)
	local end_row, end_col = node:end_()
	local tail = M.__text_between(bufnr, end_row, end_col, row, col)

	local trimmed = tail:gsub("^%s+", "")
	if trimmed:sub(1, 1) ~= "(" then
		return false
	end

	local depth = 0
	local quote = nil

	for index = 1, #trimmed do
		local char = trimmed:sub(index, index)

		if quote then
			if char == quote then
				quote = nil
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "(" then
			depth = depth + 1
		elseif char == ")" then
			depth = depth - 1
		end
	end

	return depth > 0
end

--- Determine the argument kind and the typed prefix
--- @param anchor TSNode|nil
--- @param attribute TSNode|nil Call target found by __find_chain
--- @param row number
--- @param col number
--- @param bufnr number
--- @return string arg_kind, string prefix
function M.__argument(anchor, attribute, row, col, bufnr)
	local node = anchor

	-- 1. A complete keyword argument: the name carries the path
	local keyword = M.__ancestor(node, "keyword_argument")
	if keyword then
		local name = keyword:field("name")[1]

		if name then
			local name_row, name_col = name:start()
			local name_end_row, name_end_col = name:end_()

			-- Past the name the cursor sits on the value, which is not a path
			if name_row == row and name_col <= col and col <= name_end_col then
				return "keyword", M.__identifier_prefix(name, row, col, bufnr)
			end

			if name_end_row ~= row then
				return "none", ""
			end

			return "none", ""
		end
	end

	-- 2. A string literal: the content is the path
	local string = M.__ancestor(node, "string")
	if string then
		return "string", M.__string_prefix(string, row, col, bufnr)
	end

	-- 3. A complete argument list
	local arguments = M.__ancestor(node, "argument_list")
	if arguments then
		if node and node:type() == "identifier" then
			return "positional", M.__identifier_prefix(node, row, col, bufnr)
		end

		return M.__empty_slot(attribute, row, col, bufnr)
	end

	-- 4. An incomplete call: the parser keeps the argument being typed as a
	--    sibling of the call target inside an ERROR node.
	return M.__incomplete_argument(node, attribute, row, col, bufnr)
end

--- Prefix of an identifier up to the cursor
--- @param node TSNode
--- @param row number
--- @param col number
--- @param bufnr number
--- @return string
function M.__identifier_prefix(node, row, col, bufnr)
	local text = M.__text(node, bufnr)
	local start_row, start_col = node:start()

	if start_row ~= row then
		return text
	end

	return text:sub(1, math.max(0, math.min(#text, col - start_col)))
end

--- Prefix of a string literal up to the cursor
--- @param node TSNode
--- @param row number
--- @param col number
--- @param bufnr number
--- @return string
function M.__string_prefix(node, row, col, bufnr)
	local start_row, start_col = node:start()
	local end_row, end_col = node:end_()

	-- Skip the opening quote and stop at the closing one
	local from_row, from_col = start_row, start_col + 1
	local to_row = math.min(row, end_row)
	local to_col = col

	if to_row == end_row then
		to_col = math.min(col, math.max(end_col - 1, from_col))
	end

	local text = M.__text_between(bufnr, from_row, from_col, to_row, to_col)

	return (text:gsub("[\"']$", ""))
end

--- Prefix typed in the argument slot that follows the call target
--- Only the current argument is kept: everything up to the last top level
--- comma belongs to previous arguments.
--- @param attribute TSNode|nil
--- @param row number
--- @param col number
--- @param bufnr number
--- @return string
function M.__tail_prefix(attribute, row, col, bufnr)
	if not attribute then
		return ""
	end

	local end_row, end_col = attribute:end_()
	local tail = M.__text_between(bufnr, end_row, end_col, row, col)
	tail = tail:gsub("^%s*%(", "")

	local segment = tail:match("([^,]*)$") or ""

	return (segment:gsub("^%s+", ""))
end

--- Handle an argument slot without any node yet
--- @param attribute TSNode|nil
--- @param row number
--- @param col number
--- @param bufnr number
--- @return string arg_kind, string prefix
function M.__empty_slot(attribute, row, col, bufnr)
	return "bare", M.__tail_prefix(attribute, row, col, bufnr)
end

--- Handle the argument being typed in an incomplete call
--- @param node TSNode|nil
--- @param attribute TSNode|nil
--- @param row number
--- @param col number
--- @param bufnr number
--- @return string arg_kind, string prefix
function M.__incomplete_argument(node, attribute, row, col, bufnr)
	local statement = M.__statement(node) or node
	if not statement then
		return "none", ""
	end

	local candidate = nil

	for _, child in ipairs(statement:named_children()) do
		if child:type() == "identifier" and M.__ends_before(child, row, col) then
			candidate = child
		end
	end

	if not candidate and node then
		if node:type() == "identifier" and M.__ends_before(node, row, col) then
			candidate = node
		elseif node:type() == "string_start" then
			return "string", M.__text_between(bufnr, select(1, node:end_()), select(2, node:end_()), row, col)
		end
	end

	if candidate then
		local previous = M.__sibling_before(candidate)

		if previous and previous:type() == "string_start" then
			local previous_row, previous_col = previous:end_()
			local text = M.__text_between(bufnr, previous_row, previous_col, row, col)
			return "string", (text:gsub("[\"']$", ""))
		end

		local _, candidate_col = candidate:end_()
		if M.__char(bufnr, row, candidate_col) == "=" then
			-- The cursor already moved past the equals sign: value position
			if col > candidate_col then
				return "none", ""
			end

			return "keyword", M.__identifier_prefix(candidate, row, col, bufnr)
		end

		return "bare", M.__identifier_prefix(candidate, row, col, bufnr)
	end

	-- Nothing parsed yet: the cursor follows an opening parenthesis or comma
	if attribute then
		return "bare", M.__tail_prefix(attribute, row, col, bufnr)
	end

	return "none", ""
end

--- Find the enclosing scope of the cursor (function definition or module)
--- @param anchor TSNode|nil
--- @return TSNode|nil
function M.__scope(anchor)
	local node = anchor

	while node do
		local node_type = node:type()
		if node_type == "function_definition" or node_type == "class_definition" then
			return node
		end
		node = node:parent()
	end

	return nil
end

--- Resolve the model a receiver expression refers to
--- @param bufnr number
--- @param chain string[]
--- @param scope TSNode|nil
--- @return string|nil
function M.__receiver(bufnr, chain, scope)
	local receiver = chain[1]
	if not receiver or receiver == "()" then
		return nil
	end

	local model_name = imports.resolve_name(bufnr, receiver, scope)
	if model_name then
		return model_name
	end

	-- A direct model reference: Post.objects.filter(...)
	if chain[2] == "objects" then
		return receiver
	end

	return nil
end

--- Analyse the syntax around the cursor
--- The model is only reported when the receiver can be resolved; the rest of
--- the shape (method, prefix, argument kind) is always available.
--- @param bufnr number
--- @param row number 0-indexed row
--- @param col number 0-indexed byte column
--- @return DjangoOrmContext|nil
function M.analyze(bufnr, row, col)
	local anchor = M.__node_at(bufnr, row, col)
	if not anchor then
		return nil
	end

	local chain, method, attribute = M.__find_chain(anchor, row, col, bufnr)
	if not method or method == "" then
		return nil
	end

	local arg_kind, prefix = M.__argument(anchor, attribute, row, col, bufnr)
	if arg_kind == "none" then
		return nil
	end

	local scope = M.__scope(anchor)
	local model_name = M.__receiver(bufnr, chain, scope)

	return {
		model_name = model_name,
		method = method,
		prefix = prefix,
		arg_kind = arg_kind,
		chain = chain,
		scope = scope,
	}
end

--- Resolve the ORM completion context from the syntax tree
--- @param bufnr number
--- @param row number 0-indexed row
--- @param col number 0-indexed byte column
--- @return DjangoOrmContext|nil
function M.resolve(bufnr, row, col)
	local context = M.analyze(bufnr, row, col)

	if not context or not context.model_name then
		return nil
	end

	return context
end

--- Whether the buffer has a usable python parser
--- @param bufnr number
--- @return boolean
function M.is_available(bufnr)
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
	return ok and parser ~= nil
end

return M

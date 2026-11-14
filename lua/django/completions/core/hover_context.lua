--- LSP hover fallback for ORM context inference.
---
--- The syntax tree is the primary engine. Hover is only consulted when the
--- parser sees a Django style call but cannot tell which model the receiver
--- holds, e.g. `self.get_queryset().filter(...)` or a receiver imported
--- through a wildcard import.
local M = {}

local async = require("django.async")

--- Resolve the model of the current call chain through LSP hover
--- Must be called within async.run()
--- @param bufnr number
--- @param line number 0-indexed line
--- @param col number 0-indexed column
--- @return string|nil model_name
function M.resolve(bufnr, line, col)
	local methods = M.__method_chain(bufnr, line, col)
	if #methods == 0 then
		return nil
	end

	-- Walk the chain backwards: methods such as update() return a row count,
	-- so the model has to be read from an earlier call in the chain.
	for index = #methods, 1, -1 do
		local info = methods[index]
		local params = {
			textDocument = vim.lsp.util.make_text_document_params(bufnr),
			position = { line = info.line, character = info.col },
		}

		local err, result = async.lsp_request(bufnr, "textDocument/hover", params)
		if not err and result and result.contents then
			local model_name = M.extract_model(result.contents)
			if model_name then
				return model_name
			end
		end
	end

	return nil
end

--- Find the `.method(` calls of the chain before the cursor
--- @param bufnr number
--- @param line number 0-indexed line
--- @param col number 0-indexed column
--- @return table[] { line, method, col }
function M.__method_chain(bufnr, line, col)
	local start_line = math.max(0, line - 20)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, line + 1, false)

	for index = #lines, 1, -1 do
		local text = lines[index]
		local actual_line = start_line + index - 1
		local limit = actual_line == line and col or #text

		local methods = {}
		local position = 1

		while position <= limit do
			local dot, finish, name = text:find("%.([%w_]+)%s*%(", position)
			if not dot or dot > limit then
				break
			end

			table.insert(methods, { line = actual_line, method = name, col = dot })
			position = finish + 1
		end

		if #methods > 0 then
			return methods
		end
	end

	return {}
end

--- Extract the model name from LSP hover contents
--- Matches "Manager[Post]", "QuerySet[Post]" and "ValuesQuerySet[Post, ...]".
--- @param contents any
--- @return string|nil
function M.extract_model(contents)
	local text = ""

	if type(contents) == "string" then
		text = contents
	elseif type(contents) == "table" then
		if contents.value then
			text = contents.value
		elseif contents[1] then
			text = type(contents[1]) == "string" and contents[1] or (contents[1].value or "")
		end
	end

	return text:match("Manager%[([%w_]+)") or text:match("QuerySet%[([%w_]+)")
end

return M

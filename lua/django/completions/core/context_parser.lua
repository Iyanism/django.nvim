--- Resolve the ORM completion context.
---
--- The tree-sitter resolver is the primary engine. LSP hover is only asked
--- when the parser sees a Django style call but cannot tell which model the
--- receiver holds, which keeps hover traffic close to zero.
local M = {}

local ts_context = require("django.completions.core.ts_context")
local hover_context = require("django.completions.core.hover_context")
local imports = require("django.completions.core.imports")
local ModelData = require("django.completions.core.model_data")

---@class DjangoCompletionContext
---@field model_name string Model the ORM path is rooted at
---@field method string QuerySet method
---@field prefix string Path typed so far
---@field arg_kind "keyword"|"positional"|"string"|"bare"
---@field source "treesitter"|"hover"

--- Resolve the completion context at a position
--- Must be called within async.run()
--- @param bufnr number
--- @param line number 0-indexed line
--- @param col number 0-indexed column
--- @return DjangoCompletionContext|nil
function M.parse(bufnr, line, col)
	local shape = ts_context.analyze(bufnr, line, col)
	if not shape then
		return nil
	end

	if shape.model_name and M.is_known_model(shape.model_name) then
		return M.__context(shape, shape.model_name, "treesitter")
	end

	if not M.__wants_hover(bufnr, shape) then
		return nil
	end

	local model_name = hover_context.resolve(bufnr, line, col)
	if not model_name then
		return nil
	end

	return M.__context(shape, model_name, "hover")
end

--- Check whether the runtime schema knows a model
--- @param model_name string
--- @return boolean
function M.is_known_model(model_name)
	local model_data = ModelData.get_instance()
	if not model_data then
		-- Without schema data there is nothing better to try
		return true
	end

	return model_data:get_model(model_name) ~= nil
end

--- Whether the receiver looks like a Django queryset worth a hover request
--- @param bufnr number
--- @param shape DjangoOrmContext
--- @return boolean
function M.__wants_hover(bufnr, shape)
	local chain = shape.chain
	if chain[2] == "objects" or chain[2] == "get_queryset" then
		return true
	end

	local receiver = chain[1]
	if not receiver then
		return false
	end

	local assignment = imports.assignment_chain(bufnr, receiver, shape.scope)
	if not assignment then
		return false
	end

	return assignment:find("%.objects") ~= nil or assignment:find("get_queryset") ~= nil
end

--- Build the context returned to callers
--- @param shape DjangoOrmContext
--- @param model_name string
--- @param source "treesitter"|"hover"
--- @return DjangoCompletionContext
function M.__context(shape, model_name, source)
	return {
		model_name = model_name,
		method = shape.method,
		prefix = shape.prefix,
		arg_kind = shape.arg_kind,
		source = source,
	}
end

return M

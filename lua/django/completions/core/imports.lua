--- Import and variable resolution for ORM context inference.
---
--- Both maps are derived from the buffer itself with tree-sitter queries, so
--- no runtime schema change is needed to support aliases such as
--- `from blog.models import Post as P`.
local M = {}

--- Queries used to collect imports and assignments
M.IMPORT_QUERY = [[
(import_from_statement
  module_name: (_) @module
  name: (dotted_name) @name)

(import_from_statement
  module_name: (_) @module
  name: (aliased_import
    name: (dotted_name) @name
    alias: (identifier) @alias))
]]

M.ASSIGNMENT_QUERY = [[
(assignment
  left: (identifier) @name
  right: (call function: [(attribute) (identifier)] @fn))
]]

--- Per buffer cache: bufnr -> { tick = number, aliases = table }
local cache = {}

--- Get the root node of a buffer
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

--- Build the import alias map of a buffer
--- Both the imported name and the alias resolve to the real model name.
--- @param bufnr number
--- @return table<string, { name: string, module: string|nil }>
function M.alias_map(bufnr)
	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = cache[bufnr]
	if cached and cached.tick == tick then
		return cached.aliases
	end

	local aliases = M.__collect_aliases(bufnr)

	M.__prune()
	cache[bufnr] = { tick = tick, aliases = aliases }

	return aliases
end

--- Forget the aliases of buffers that no longer exist
function M.__prune()
	for cached_bufnr in pairs(cache) do
		if not vim.api.nvim_buf_is_valid(cached_bufnr) then
			cache[cached_bufnr] = nil
		end
	end
end

--- Collect the import alias map without touching the cache
--- @param bufnr number
--- @return table<string, { name: string, module: string|nil }>
function M.__collect_aliases(bufnr)
	local root = M.__root(bufnr)
	if not root then
		return {}
	end

	local ok, query = pcall(vim.treesitter.query.parse, "python", M.IMPORT_QUERY)
	if not ok then
		return {}
	end

	local aliases = {}

	for _, match in query:iter_matches(root, bufnr, 0, -1) do
		local module = nil
		local name = nil
		local alias = nil

		for id, nodes in pairs(match) do
			local capture = query.captures[id]
			local node = type(nodes) == "table" and nodes[1] or nodes

			if node then
				local text = vim.treesitter.get_node_text(node, bufnr)
				if capture == "module" then
					module = text
				elseif capture == "name" then
					name = text
				elseif capture == "alias" then
					alias = text
				end
			end
		end

		if name then
			aliases[name] = { name = name, module = module }
			if alias then
				aliases[alias] = { name = name, module = module }
			end
		end
	end

	return aliases
end

--- Find the call chain a variable was assigned from
--- The search is limited to the given scope so that same named variables in
--- other scopes are ignored.
--- @param bufnr number
--- @param name string
--- @param scope_node TSNode|nil Node limiting the search
--- @return string|nil chain e.g. "Post.objects.all"
function M.assignment_chain(bufnr, name, scope_node)
	local root = M.__root(bufnr)
	if not root then
		return nil
	end

	local ok, query = pcall(vim.treesitter.query.parse, "python", M.ASSIGNMENT_QUERY)
	if not ok then
		return nil
	end

	local scope = scope_node or root
	local start_row = scope:start()
	local end_row = scope:end_()
	local found = nil

	for _, match in query:iter_matches(scope, bufnr, start_row, end_row) do
		local variable = nil
		local chain = nil

		for id, nodes in pairs(match) do
			local capture = query.captures[id]
			local node = type(nodes) == "table" and nodes[1] or nodes

			if node then
				local text = vim.treesitter.get_node_text(node, bufnr)
				if capture == "name" then
					variable = text
				elseif capture == "fn" then
					chain = text
				end
			end
		end

		if variable == name and chain then
			found = chain
		end
	end

	return found
end

--- Resolve a local variable to the receiver it was assigned from
--- @param bufnr number
--- @param name string
--- @param scope_node TSNode|nil Node limiting the search
--- @return string|nil receiver e.g. "Post"
function M.resolve_variable(bufnr, name, scope_node)
	local chain = M.assignment_chain(bufnr, name, scope_node)
	if not chain then
		return nil
	end

	local base = chain:match("^([%w_]+)")
	if base and base ~= name then
		return base
	end

	return nil
end

--- Resolve an identifier to a model name using imports and variables
--- @param bufnr number
--- @param name string
--- @param scope_node TSNode|nil
--- @return string|nil model_name
function M.resolve_name(bufnr, name, scope_node)
	if not name or name == "" then
		return nil
	end

	local alias = M.alias_map(bufnr)[name]
	if alias then
		return alias.name
	end

	return M.resolve_variable(bufnr, name, scope_node)
end

return M

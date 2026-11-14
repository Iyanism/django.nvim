--- Minimal bootstrap for headless test runs.
--- Usage: nvim --headless --noplugin -u NONE -l tests/run.lua
local this_file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this_file, ":p:h:h")

vim.opt.runtimepath:prepend(root)

package.path = table.concat({
	root .. "/lua/?.lua",
	root .. "/lua/?/init.lua",
	root .. "/tests/?.lua",
	package.path,
}, ";")

return { root = root }

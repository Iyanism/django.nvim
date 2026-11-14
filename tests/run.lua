--- Headless test runner.
--- Usage: nvim --headless --noplugin -u NONE -l tests/run.lua
--- Exit code is 0 when every spec passes, 1 otherwise.
local this_file = debug.getinfo(1, "S").source:sub(2)
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h")

local bootstrap = dofile(tests_dir .. "/minimal_init.lua")
local helpers = require("helpers")

local specs = vim.fn.glob(tests_dir .. "/unit/*_spec.lua", false, true)
table.sort(specs)

if #specs == 0 then
	io.write("No specs found in " .. tests_dir .. "/unit\n")
	vim.cmd("cq!")
end

for _, spec in ipairs(specs) do
	io.write(string.format("\n== %s ==\n", vim.fn.fnamemodify(spec, ":t")))
	local ok, err = pcall(dofile, spec)
	if not ok then
		helpers.__record(vim.fn.fnamemodify(spec, ":t"), "<load>", debug.traceback(tostring(err), 2))
	end
end

io.write(string.format("\nRepository root: %s\n", bootstrap.root))

local success = helpers.summary()
vim.cmd(success and "qa!" or "cq!")

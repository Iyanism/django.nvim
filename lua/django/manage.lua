--- manage.py command runner.
--- Runs Django management commands in a Snacks terminal using the resolved
--- interpreter and the project root as the working directory.
local M = {}

local utils = require("django.utils")

--- @class DjangoManageCommand
--- @field name string User command name
--- @field args string[] Arguments passed to manage.py
--- @field desc string Command description
--- @field nargs string|nil User command nargs ("0" or "*")

M.commands = {
	{ name = "DjangoMigrate", args = { "migrate" }, desc = "Apply database migrations" },
	{
		name = "DjangoMakeMigrations",
		args = { "makemigrations" },
		desc = "Create new migrations",
		nargs = "*",
	},
	{ name = "DjangoCheck", args = { "check" }, desc = "Run Django system checks" },
	{ name = "DjangoTest", args = { "test" }, desc = "Run the test suite", nargs = "*" },
	{
		name = "DjangoRunserver",
		args = { "runserver" },
		desc = "Start the development server",
		nargs = "*",
	},
	{
		name = "DjangoShowmigrations",
		args = { "showmigrations" },
		desc = "Show migration status",
	},
}

--- Build the shell command for a manage.py invocation
--- @param args string[]|nil Arguments passed to manage.py
--- @return string|nil command
--- @return string|nil error
function M.build_command(args)
	local root = utils.get_project_root()
	if not root then
		return nil, "Not a Django project: manage.py not found"
	end

	local manage_py = root .. "/manage.py"
	if vim.fn.filereadable(manage_py) ~= 1 then
		return nil, "manage.py not found at " .. manage_py
	end

	local parts = {
		utils.get_python_command_string(),
		vim.fn.shellescape(manage_py),
	}

	for _, arg in ipairs(args or {}) do
		table.insert(parts, vim.fn.shellescape(arg))
	end

	return table.concat(parts, " "), nil
end

--- Run a manage.py command in a Snacks terminal
--- @param args string[]|nil Arguments passed to manage.py
--- @param opts table|nil Options: { position = string|nil, cwd = string|nil, auto_close = boolean|nil }
--- @return string|nil command The command that was launched
function M.run(args, opts)
	opts = opts or {}

	local command, err = M.build_command(args)
	if not command then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local ok, Snacks = pcall(require, "snacks")
	if not ok then
		vim.notify("snacks.nvim is required for Django manage commands", vim.log.levels.ERROR)
		return nil
	end

	local cfg = require("django.config").current.manage or {}

	local auto_close = opts.auto_close
	if auto_close == nil then
		auto_close = cfg.auto_close
	end

	Snacks.terminal.toggle(command, {
		win = { position = opts.position or cfg.position or "right" },
		cwd = opts.cwd or utils.get_project_root(),
		auto_close = auto_close,
	})

	return command
end

return M

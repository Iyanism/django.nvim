--- Opt-in language server presets.
---
--- Neither preset is enabled by default: the completions and diagnostics of
--- this plugin work without a language server. When a preset is enabled the
--- server is registered through `vim.lsp.config` and started for Python
--- buffers, with the Django environment injected where the server wants it.
local M = {}

local config = require("django.config")
local utils = require("django.utils")

--- Root markers shared by the presets
M.ROOT_MARKERS = { "manage.py", "pyproject.toml", ".git" }

--- Install hints used when an executable is missing
M.HINTS = {
	ty = "uv tool install ty",
	pogo = "download pogo from https://github.com/amirhasanzadehpy/Pogo/releases",
}

--- Register the enabled presets
--- @return table<string, boolean> enabled Presets that were started
function M.setup()
	local lsp = config.current.lsp or {}
	local enabled = {}

	if lsp.ty and lsp.ty.enabled then
		enabled.ty = M.setup_ty()
	end

	if lsp.pogo and lsp.pogo.enabled then
		enabled.pogo = M.setup_pogo()
	end

	return enabled
end

--- Register and start the ty language server
--- @return boolean started
function M.setup_ty()
	local preset = M.ty_config()

	if not M.is_installed(preset.cmd) then
		M.__notify_missing("ty")
		return false
	end

	vim.lsp.config("ty", preset)
	vim.lsp.enable("ty")

	return true
end

--- Register and start the pogo language server
--- @return boolean started
function M.setup_pogo()
	local preset = M.pogo_config()

	if not M.is_installed(preset.cmd) then
		M.__notify_missing("pogo")
		return false
	end

	vim.lsp.config("pogo", preset)
	vim.lsp.enable("pogo")

	return true
end

--- Configuration of the ty preset
--- @return table
function M.ty_config()
	return {
		cmd = { "ty", "server" },
		filetypes = { "python" },
		root_markers = M.ROOT_MARKERS,
	}
end

--- Configuration of the pogo preset
--- The Django environment is injected as `initializationOptions.djangoOrm`
--- (the documented contract), which pogo uses to bootstrap the ORM index.
--- The log file lets `:DjangoDoctor` report schema readiness and errors.
--- @return table
function M.pogo_config()
	local preset = {
		cmd = { "pogo", "-log-file", M.log_path() },
		filetypes = { "python" },
		root_markers = M.ROOT_MARKERS,
	}

	local options = M.django_orm_options()
	if options then
		preset.init_options = { djangoOrm = options }
	end

	return preset
end

--- Path of the pogo log the preset asks the server to write
--- @return string
function M.log_path()
	local directory = vim.fn.stdpath("cache") .. "/django.nvim"
	vim.fn.mkdir(directory, "p")
	return directory .. "/pogo.log"
end

--- Django environment handed to ORM aware servers
--- @return table|nil options
function M.django_orm_options()
	local root = utils.get_project_root()
	if not root then
		return nil
	end

	return {
		projectRoot = root,
		pythonPath = utils.get_python_executable(),
		settingsModule = utils.get_settings_module(),
	}
end

--- Whether the executable of a preset is on PATH
--- @param cmd string[]
--- @return boolean
function M.is_installed(cmd)
	return vim.fn.executable(cmd[1]) == 1
end

--- Tell the user which preset is enabled but unusable
--- @param name string
function M.__notify_missing(name)
	vim.notify(
		string.format("django.nvim: the %s preset is enabled but %s is not on PATH (%s)", name, name, M.HINTS[name]),
		vim.log.levels.WARN
	)
end

return M

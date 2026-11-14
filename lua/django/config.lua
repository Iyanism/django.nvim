local M = {}

M.default = {
	python = nil, -- string|string[]: explicit interpreter, e.g. "/path/.venv/bin/python" or { "uv", "run", "python" }
	views = {
		auto_refresh = {
			on_picker_open = true,
			file_watch_patterns = {
				"**/urls.py",
				"**/views.py",
				"**/view.py",
				"**/*views.py",
				"**/*view.py",
				"**/*viewset.py",
				"**/*view_set.py",
				"**/*api.py",
			},
		},
	},
	models = {
		auto_refresh = {
			on_picker_open = true,
			file_watch_patterns = { "**/models.py", "**/models/*.py" },
		},
	},
	completions = {
		auto_refresh = {
			file_watch_patterns = { "**/models.py", "**/models/*.py" },
		},
	},
	shell = {
		command = "shell", -- "shell", "shell_plus", "shell_plus --ipython", etc.
		position = "right", -- "bottom", "top", "left", "right", "float"
		env = {}, -- explicit environment variables (e.g. { DJANGO_SETTINGS_MODULE = "myproject.settings" })
	},
	manage = {
		position = "right", -- terminal position for manage.py commands
		auto_close = false, -- keep output visible after the command finishes
	},
	diagnostics = {
		enabled = true, -- static ORM path diagnostics on write
		debounce_ms = 300, -- delay before a buffer is checked
	},
}

M.current = vim.deepcopy(M.default)

function M.setup(opts)
	M.current = vim.tbl_deep_extend("force", M.default, opts or {})
end

return M

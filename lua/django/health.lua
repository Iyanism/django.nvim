--- Environment diagnostics for django.nvim.
--- Backs both `:DjangoDoctor` and `:checkhealth django`.
local M = {}

local utils = require("django.utils")

--- @class DjangoHealthItem
--- @field name string
--- @field status "ok"|"warn"|"error"|"info"|"skipped"
--- @field message string
--- @field hint string|nil

--- Timeout for a single Python/tool probe (milliseconds)
M.PROBE_TIMEOUT = 10000

--- Cache names inspected by the doctor
M.CACHE_NAMES = { "DjangoViews", "DjangoModels", "completions" }

--- Display order for report items
M.ORDER = {
	"project_root",
	"interpreter",
	"python_executable",
	"settings_module",
	"django",
	"django_types",
	"ty",
	"pogo",
	"python_lsp",
	"treesitter_python",
	"cache:DjangoViews",
	"cache:DjangoModels",
	"cache:completions",
	"completion_ready",
}

M.STATUS_ICONS = {
	ok = "✓",
	warn = "!",
	error = "✗",
	info = "i",
	skipped = "-",
}

--- Collect cheap, synchronous health items (no subprocesses)
--- @return DjangoHealthItem[]
function M.inspect()
	local items = {}
	local root = utils.get_project_root()

	if root then
		table.insert(items, { name = "project_root", status = "ok", message = root })
	else
		table.insert(items, {
			name = "project_root",
			status = "error",
			message = "manage.py not found",
			hint = "open a file inside a Django project (the directory containing manage.py)",
		})
	end

	local command = utils.get_python_command()
	table.insert(items, {
		name = "interpreter",
		status = "ok",
		message = string.format("%s (%s)", table.concat(command, " "), M.__describe_interpreter(root)),
		hint = "set `python` in setup() to override interpreter resolution",
	})

	local executable = utils.get_python_executable()
	if executable then
		table.insert(items, { name = "python_executable", status = "ok", message = executable })
	else
		table.insert(items, {
			name = "python_executable",
			status = "warn",
			message = "no concrete interpreter path found",
			hint = 'tools such as pogo require a real path; set python = "/path/to/.venv/bin/python"',
		})
	end

	local settings_module = utils.get_settings_module()
	if settings_module then
		table.insert(items, { name = "settings_module", status = "ok", message = settings_module })
	else
		table.insert(items, {
			name = "settings_module",
			status = "warn",
			message = "could not determine DJANGO_SETTINGS_MODULE",
			hint = "define DJANGO_SETTINGS_MODULE in manage.py or the environment",
		})
	end

	local has_parser = utils.has_treesitter_parser("python")
	if has_parser then
		table.insert(items, { name = "treesitter_python", status = "ok", message = "python parser available" })
	else
		table.insert(items, {
			name = "treesitter_python",
			status = "warn",
			message = "python parser not installed",
			hint = "install the python parser with nvim-treesitter (`:TSInstall python`)",
		})
	end

	local clients = vim.lsp.get_clients({ bufnr = 0 })
	if #clients == 0 then
		table.insert(items, {
			name = "python_lsp",
			status = "warn",
			message = "no LSP client attached to the current buffer",
			hint = "install ty or pyright and attach it to Python buffers",
		})
	else
		local names = {}
		for _, client in ipairs(clients) do
			table.insert(names, client.name)
		end
		table.sort(names)
		table.insert(items, { name = "python_lsp", status = "ok", message = "attached: " .. table.concat(names, ", ") })
	end

	local cache = require("django.fetcher.cache")
	for _, cache_name in ipairs(M.CACHE_NAMES) do
		table.insert(items, M.__cache_item(cache, cache_name, root))
	end

	local has_cache = vim.fn.filereadable(cache.path("completions", root)) == 1
	if not root then
		table.insert(items, {
			name = "completion_ready",
			status = "error",
			message = "inactive (not a Django project)",
		})
	elseif not has_cache then
		table.insert(items, {
			name = "completion_ready",
			status = "warn",
			message = "schema is not cached yet",
			hint = "run :DjangoCompletionsRefresh",
		})
	elseif not has_parser and #clients == 0 then
		table.insert(items, {
			name = "completion_ready",
			status = "warn",
			message = "model inference unavailable (no python parser and no LSP client)",
			hint = "install the python parser or a Python LSP",
		})
	else
		table.insert(items, { name = "completion_ready", status = "ok", message = "ready" })
	end

	return items
end

--- Run the synchronous checks plus asynchronous probes
--- @param on_done fun(items: DjangoHealthItem[])
function M.probe(on_done)
	local items = M.inspect()
	local slots = {}
	local remaining = 0

	local function complete(index, item)
		slots[index] = item
		remaining = remaining - 1
		if remaining == 0 then
			for _, slot in ipairs(slots) do
				table.insert(items, slot)
			end
			on_done(M.__sort_items(items))
		end
	end

	local function schedule(index, argv, transform)
		remaining = remaining + 1
		M.__run_probe(argv, M.PROBE_TIMEOUT, function(result)
			complete(index, transform(result))
		end)
	end

	local function immediate(index, item)
		slots[index] = item
	end

	schedule(1, utils.get_python_argv("import django; print(django.get_version())"), function(result)
		return M.__probe_item("django", result, function(version)
			return "Django " .. version
		end, "install django in the resolved environment")
	end)

	schedule(
		2,
		utils.get_python_argv(
			'import importlib.metadata as m; print(m.version("django-types"))'
		),
		function(result)
			return M.__probe_item("django_types", result, function(version)
				return "django-types " .. version
			end, "uv add --dev django-types")
		end
	)

	local ty = vim.fn.exepath("ty")
	if ty ~= "" then
		schedule(3, { ty, "--version" }, function(result)
			return M.__probe_item("ty", result, function(version)
				return version
			end, "uv tool install ty")
		end)
	else
		immediate(3, { name = "ty", status = "warn", message = "not found on PATH", hint = "uv tool install ty" })
	end

	local pogo = vim.fn.exepath("pogo")
	if pogo ~= "" then
		immediate(4, { name = "pogo", status = "ok", message = pogo })
	else
		immediate(4, {
			name = "pogo",
			status = "warn",
			message = "not found on PATH",
			hint = "optional Django ORM LSP: https://github.com/amirhasanzadehpy/Pogo/releases",
		})
	end

	if remaining == 0 then
		on_done(M.__sort_items(items))
	end
end

--- Render health items as markdown lines
--- @param items DjangoHealthItem[]
--- @return string[]
function M.render(items)
	local lines = { "# django.nvim health", "" }

	for _, item in ipairs(items) do
		table.insert(
			lines,
			string.format(
				"- %s **%s**: %s",
				M.STATUS_ICONS[item.status] or "?",
				item.name,
				item.message
			)
		)
		if item.hint and item.status ~= "ok" then
			table.insert(lines, "  - hint: " .. item.hint)
		end
	end

	return lines
end

--- Open the full report in a scratch buffer (`:DjangoDoctor`)
function M.open_report()
	vim.notify("django.nvim: probing environment…", vim.log.levels.INFO)
	M.probe(function(items)
		M.__open_scratch(M.render(items))
	end)
end

--- `:checkhealth django` entry point
function M.check()
	local items
	local done = false

	M.probe(function(result)
		items = result
		done = true
	end)

	vim.wait(M.PROBE_TIMEOUT + 2000, function()
		return done
	end, 50)

	vim.health.start("django.nvim")

	if not items then
		vim.health.warn("probe timed out")
		return
	end

	for _, item in ipairs(items) do
		local message = string.format("%s: %s", item.name, item.message)
		if item.status == "ok" then
			vim.health.ok(message)
		elseif item.status == "warn" then
			M.__health_report("warn", message, item.hint)
		elseif item.status == "error" then
			M.__health_report("error", message, item.hint)
		else
			vim.health.info(message)
		end
	end
end

--- Run a probe asynchronously
--- @param argv string[]
--- @param timeout number Milliseconds
--- @param on_done fun(result: table|nil)
function M.__run_probe(argv, timeout, on_done)
	local function finish(result)
		vim.schedule(function()
			on_done(result)
		end)
	end

	local ok = pcall(vim.system, argv, {
		cwd = utils.get_project_root(),
		text = true,
		timeout = timeout,
	}, finish)

	if not ok then
		finish(nil)
	end
end

--- Run a probe synchronously (used by tests and blocking callers)
--- @param argv string[]
--- @param timeout number Milliseconds
--- @return table|nil result
--- @return boolean incomplete
function M.__run_probe_sync(argv, timeout)
	local result
	local done = false

	local ok = pcall(vim.system, argv, {
		cwd = utils.get_project_root(),
		text = true,
		timeout = timeout,
	}, function(res)
		result = res
		done = true
	end)

	if not ok then
		return nil, true
	end

	vim.wait(timeout + 1000, function()
		return done
	end, 20)

	return result, not done
end

--- Convert a probe result into a health item
--- @param name string
--- @param result table|nil
--- @param on_success fun(version: string): string
--- @param hint string
--- @return DjangoHealthItem
function M.__probe_item(name, result, on_success, hint)
	if not result then
		return { name = name, status = "warn", message = "probe could not start", hint = hint }
	end

	if result.code == 124 then
		return { name = name, status = "warn", message = "probe timed out", hint = hint }
	end

	if result.code ~= 0 then
		local detail = M.__first_line(result.stderr)
			or M.__first_line(result.stdout)
			or ("exit code " .. tostring(result.code))
		return { name = name, status = "error", message = detail, hint = hint }
	end

	local version = M.__first_line(result.stdout) or "installed"
	return { name = name, status = "ok", message = on_success(version) }
end

--- Describe how the interpreter was resolved
--- @param root string|nil
--- @return string
function M.__describe_interpreter(root)
	if utils.is_uv_project(root) then
		return "uv"
	end

	local executable = utils.get_python_executable()
	if not executable then
		return "system"
	end

	if root and executable:find(root .. "/.venv", 1, true) then
		return "project .venv"
	end

	if root and executable:find(root .. "/venv", 1, true) then
		return "project venv"
	end

	return "environment"
end

--- Build a cache health item
--- @param cache table django.fetcher.cache module
--- @param cache_name string
--- @param root string|nil
--- @return DjangoHealthItem
function M.__cache_item(cache, cache_name, root)
	local path = cache.path(cache_name, root)
	local stat = vim.uv.fs_stat(path)

	if not stat then
		return {
			name = "cache:" .. cache_name,
			status = "warn",
			message = "not cached",
			hint = "run :DjangoRefreshAll",
		}
	end

	local age = os.time() - stat.mtime.sec
	return {
		name = "cache:" .. cache_name,
		status = "ok",
		message = string.format("%s (%s old)", path, M.__format_age(age)),
	}
end

--- Format an age in seconds as a compact string
--- @param seconds number
--- @return string
function M.__format_age(seconds)
	seconds = math.max(0, math.floor(seconds))
	if seconds < 60 then
		return string.format("%ds", seconds)
	end
	if seconds < 3600 then
		return string.format("%dm", math.floor(seconds / 60))
	end
	if seconds < 86400 then
		return string.format("%dh", math.floor(seconds / 3600))
	end
	return string.format("%dd", math.floor(seconds / 86400))
end

--- Get the first non-empty line of a string
--- @param text string|nil
--- @return string|nil
function M.__first_line(text)
	if not text then
		return nil
	end

	for line in text:gmatch("[^\r\n]+") do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			return trimmed
		end
	end

	return nil
end

--- Sort items into a stable display order
--- @param items DjangoHealthItem[]
--- @return DjangoHealthItem[]
function M.__sort_items(items)
	table.sort(items, function(a, b)
		local order_a = M.__order_of(a.name)
		local order_b = M.__order_of(b.name)
		if order_a ~= order_b then
			return order_a < order_b
		end
		return a.name < b.name
	end)
	return items
end

--- Get the display order of an item name
--- @param name string
--- @return number
function M.__order_of(name)
	for index, known in ipairs(M.ORDER) do
		if name == known then
			return index
		end
	end
	return #M.ORDER + 1
end

--- Report through vim.health with optional advice
--- @param level "ok"|"warn"|"error"|"info"
--- @param message string
--- @param hint string|nil
function M.__health_report(level, message, hint)
	local report = vim.health[level]
	if hint then
		report(message, hint)
	else
		report(message)
	end
end

--- Open lines in a scratch buffer
--- @param lines string[]
--- @return number bufnr
function M.__open_scratch(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, desc = "Close Django doctor" })

	vim.cmd("botright split")
	vim.api.nvim_win_set_buf(0, buf)

	return buf
end

return M

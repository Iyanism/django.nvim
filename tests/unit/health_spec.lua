local helpers = require("helpers")
local health = require("django.health")
local config = require("django.config")

local this_file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this_file, ":p:h:h:h")

--- Build a name -> item lookup
--- @param items DjangoHealthItem[]
--- @return table<string, DjangoHealthItem>
local function index_by_name(items)
	local by_name = {}
	for _, item in ipairs(items) do
		by_name[item.name] = item
	end
	return by_name
end

helpers.describe("health", function()
	helpers.it("inspect() returns well-formed items inside a project", function()
		config.setup({})
		helpers.with_cwd(root, function()
			local items = health.inspect()
			helpers.ok(#items > 0, "expected at least one item")

			for _, item in ipairs(items) do
				helpers.ok(type(item.name) == "string", "item.name")
				helpers.ok(type(item.status) == "string", "item.status")
				helpers.ok(type(item.message) == "string", "item.message")
			end

			local by_name = index_by_name(items)
			helpers.eq("ok", by_name.project_root.status)
			helpers.eq(root, by_name.project_root.message)
			helpers.ok(by_name.interpreter ~= nil, "interpreter item")
			helpers.ok(by_name.completion_ready ~= nil, "completion_ready item")
		end)
	end)

	helpers.it("inspect() reports a missing project root", function()
		config.setup({})
		helpers.with_cwd("/tmp", function()
			local by_name = index_by_name(health.inspect())
			helpers.eq("error", by_name.project_root.status)
			helpers.eq("error", by_name.completion_ready.status)
		end)
	end)

	helpers.it("inspect() includes one item per cache", function()
		config.setup({})
		helpers.with_cwd(root, function()
			local by_name = index_by_name(health.inspect())
			for _, cache_name in ipairs(health.CACHE_NAMES) do
				helpers.ok(by_name["cache:" .. cache_name] ~= nil, "missing cache item " .. cache_name)
			end
		end)
	end)

	helpers.it("render() emits one line per item and includes hints", function()
		local items = {
			{ name = "project_root", status = "ok", message = "/tmp/project", hint = "should be hidden" },
			{ name = "ty", status = "warn", message = "not found", hint = "uv tool install ty" },
		}

		local lines = health.render(items)
		local text = table.concat(lines, "\n")

		helpers.eq("# django.nvim health", lines[1])
		helpers.contains(text, "**project_root**: /tmp/project")
		helpers.contains(text, "hint: uv tool install ty")
		helpers.ok(not text:find("should be hidden", 1, true), "ok items must not render hints")
	end)

	helpers.it("exposes the checkhealth entry point", function()
		helpers.eq("function", type(health.check))
	end)

	helpers.it("__run_probe_sync respects the timeout", function()
		if vim.fn.executable("sh") == 0 then
			helpers.skip("sh is not available")
		end

		local started = vim.uv.hrtime()
		local result, incomplete = health.__run_probe_sync({ "sh", "-c", "sleep 5" }, 100)
		local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

		helpers.ok(elapsed_ms < 3000, string.format("probe should abort quickly, took %.0fms", elapsed_ms))
		helpers.ok(not incomplete, "callback should fire after the timeout kill")
		helpers.ok(result == nil or result.code ~= 0, "expected a failed probe result")
	end)

	helpers.it("__first_line skips blank lines", function()
		helpers.eq(nil, health.__first_line(nil))
		helpers.eq(nil, health.__first_line("\n   \n"))
		helpers.eq("Django 5.2.8", health.__first_line("\nDjango 5.2.8\n"))
	end)

	helpers.it("__format_age renders compact ages", function()
		helpers.eq("30s", health.__format_age(30))
		helpers.eq("5m", health.__format_age(300))
		helpers.eq("2h", health.__format_age(7200))
		helpers.eq("3d", health.__format_age(259200))
	end)

	helpers.it("__probe_item maps results to statuses", function()
		local ok_item = health.__probe_item("django", { code = 0, stdout = "5.2.8\n", stderr = "" }, function(version)
			return "Django " .. version
		end, "hint")
		helpers.eq("ok", ok_item.status)
		helpers.eq("Django 5.2.8", ok_item.message)

		local timeout_item = health.__probe_item("django", { code = 124, stdout = "", stderr = "" }, function()
			return ""
		end, "hint")
		helpers.eq("warn", timeout_item.status)
		helpers.eq("probe timed out", timeout_item.message)

		local error_item = health.__probe_item(
			"django",
			{ code = 1, stdout = "", stderr = "ModuleNotFoundError: No module named 'django'" },
			function()
				return ""
			end,
			"hint"
		)
		helpers.eq("error", error_item.status)
		helpers.contains(error_item.message, "ModuleNotFoundError")
		helpers.eq("hint", error_item.hint)

		local missing_item = health.__probe_item("django", nil, function()
			return ""
		end, "hint")
		helpers.eq("warn", missing_item.status)
	end)

	helpers.it("__sort_items follows the display order", function()
		local items = {
			{ name = "completion_ready", status = "ok", message = "" },
			{ name = "project_root", status = "ok", message = "" },
			{ name = "django", status = "ok", message = "" },
		}

		local sorted = health.__sort_items(items)
		helpers.eq("project_root", sorted[1].name)
		helpers.eq("django", sorted[2].name)
		helpers.eq("completion_ready", sorted[3].name)
	end)
end)

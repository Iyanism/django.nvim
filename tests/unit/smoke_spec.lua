local helpers = require("helpers")

local this_file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this_file, ":p:h:h:h")

local function module_name(path)
	local rel = path:sub(#root + #"/lua/" + 1)
	local name = rel:gsub("%.lua$", ""):gsub("/init$", "")
	return (name:gsub("/", "."))
end

helpers.describe("smoke", function()
	helpers.it("loads every lua/django module", function()
		local files = vim.fn.glob(root .. "/lua/django/**/*.lua", false, true)
		helpers.ok(#files > 0, "expected at least one module")

		for _, file in ipairs(files) do
			local name = module_name(file)
			local ok, err = pcall(require, name)
			helpers.ok(ok, string.format("require(%q) failed: %s", name, tostring(err)))
		end
	end)

	helpers.it("registers user commands from plugin/django.lua", function()
		dofile(root .. "/plugin/django.lua")

		for _, command in ipairs({
			"DjangoViews",
			"DjangoModels",
			"DjangoShell",
			"DjangoRefreshAll",
			"DjangoClearAllCache",
			"DjangoDoctor",
			"DjangoManage",
		}) do
			helpers.eq(2, vim.fn.exists(":" .. command), "command :" .. command)
		end
	end)

	helpers.it("is idempotent when sourced twice", function()
		local ok, err = pcall(dofile, root .. "/plugin/django.lua")
		helpers.ok(ok, "second source failed: " .. tostring(err))
	end)
end)

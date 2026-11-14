local helpers = require("helpers")
local utils = require("django.utils")
local config = require("django.config")

local this_file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this_file, ":p:h:h:h")

helpers.describe("utils", function()
	helpers.it("get_project_root finds the repository root", function()
		helpers.with_cwd(root, function()
			helpers.eq(root, utils.get_project_root())
		end)
	end)

	helpers.it("get_project_root returns nil outside a Django project", function()
		helpers.with_cwd("/tmp", function()
			helpers.eq(nil, utils.get_project_root())
			helpers.eq(false, utils.is_django_project())
		end)
	end)

	helpers.it("is_uv_project detects uv.lock", function()
		if vim.fn.executable("uv") == 0 then
			helpers.skip("uv is not installed")
		end
		helpers.eq(true, utils.is_uv_project(root))
	end)

	helpers.it("get_python_command uses uv for this project", function()
		config.setup({})
		if vim.fn.executable("uv") == 0 then
			helpers.skip("uv is not installed")
		end
		helpers.with_cwd(root, function()
			helpers.eq({ "uv", "run", "--quiet", "python" }, utils.get_python_command())
		end)
	end)

	helpers.it("get_python_command honours config.python", function()
		config.setup({ python = { "/custom/python" } })
		helpers.eq({ "/custom/python" }, utils.get_python_command())

		config.setup({ python = "/custom/python3" })
		helpers.eq({ "/custom/python3" }, utils.get_python_command())

		config.setup({})
	end)

	helpers.it("get_python_command_string shell-escapes every argument", function()
		config.setup({ python = { "uv", "run", "python" } })
		helpers.eq("'uv' 'run' 'python'", utils.get_python_command_string())
		config.setup({})
	end)

	helpers.it("get_python_path stays a command, not a path", function()
		config.setup({ python = { "uv", "run", "python" } })
		helpers.eq("uv run python", utils.get_python_path())
		config.setup({})
	end)

	helpers.it("get_python_executable returns the project venv path", function()
		config.setup({})
		local venv_python = root .. "/.venv/bin/python"
		if vim.fn.executable(venv_python) == 0 then
			helpers.skip("project .venv is not present")
		end
		helpers.with_cwd(root, function()
			helpers.eq(venv_python, utils.get_python_executable())
		end)
	end)

	helpers.it("get_python_executable ignores a command table", function()
		config.setup({ python = { "uv", "run", "python" } })
		helpers.eq(nil, utils.__as_python_path(config.current.python))
		config.setup({})
	end)

	helpers.it("get_python_executable accepts a configured path", function()
		config.setup({ python = "/custom/python" })
		helpers.eq("/custom/python", utils.__as_python_path(config.current.python))
		config.setup({})
	end)

	helpers.it("get_settings_module reads manage.py", function()
		config.setup({})
		if vim.env.DJANGO_SETTINGS_MODULE and vim.env.DJANGO_SETTINGS_MODULE ~= "" then
			helpers.skip("DJANGO_SETTINGS_MODULE is set in the environment")
		end
		helpers.with_cwd(root, function()
			helpers.eq("project.settings", utils.get_settings_module())
		end)
	end)

	helpers.it("__parse_settings_module handles common forms", function()
		helpers.eq(
			"project.settings",
			utils.__parse_settings_module(
				[[    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'project.settings')]]
			)
		)
		helpers.eq(
			"myproject.settings",
			utils.__parse_settings_module([[    os.environ["DJANGO_SETTINGS_MODULE"] = "myproject.settings"]])
		)
		helpers.eq(
			"config.settings",
			utils.__parse_settings_module([[DJANGO_SETTINGS_MODULE = "config.settings"]])
		)
		helpers.eq(nil, utils.__parse_settings_module([[print("no settings here")]]))
		helpers.eq(nil, utils.__parse_settings_module([[DJANGO_SETTINGS_MODULE]]))
	end)

	helpers.it("get_python_argv appends -c and the snippet", function()
		config.setup({ python = { "python3" } })
		helpers.eq({ "python3", "-c", "print(1)" }, utils.get_python_argv("print(1)"))
		config.setup({})
	end)

	helpers.it("has_treesitter_parser detects bundled parsers", function()
		helpers.eq(true, utils.has_treesitter_parser("lua"))
		helpers.eq(false, utils.has_treesitter_parser("definitely-not-a-language"))
	end)

	helpers.it("has_treesitter_parser reports the python parser when installed", function()
		if not utils.has_treesitter_parser("python") then
			helpers.skip("python parser is not installed")
		end
		helpers.eq(true, utils.has_treesitter_parser("python"))
	end)
end)

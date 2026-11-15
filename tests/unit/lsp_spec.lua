local helpers = require("helpers")
local config = require("django.config")
local lsp = require("django.lsp")

local this_file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this_file, ":p:h:h:h")

helpers.describe("lsp presets", function()
	helpers.it("keeps every preset disabled by default", function()
		config.setup({})

		helpers.eq(false, config.current.lsp.ty.enabled)
		helpers.eq(false, config.current.lsp.pogo.enabled)
	end)

	helpers.it("builds the ty preset", function()
		local preset = lsp.ty_config()

		helpers.eq({ "ty", "server" }, preset.cmd)
		helpers.eq({ "python" }, preset.filetypes)
		helpers.ok(vim.tbl_contains(preset.root_markers, "manage.py"), "expected manage.py as a root marker")
	end)

	helpers.it("builds the pogo preset", function()
		local preset = lsp.pogo_config()

		helpers.eq("pogo", preset.cmd[1])
		helpers.eq("-log-file", preset.cmd[2])
		helpers.eq(lsp.log_path(), preset.cmd[3])
		helpers.eq({ "python" }, preset.filetypes)
		helpers.eq(nil, preset.before_init)
	end)

	helpers.it("injects the Django environment into pogo", function()
		config.setup({})

		helpers.with_cwd(root, function()
			local preset = lsp.pogo_config()
			local options = preset.init_options and preset.init_options.djangoOrm

			helpers.ok(options ~= nil, "expected djangoOrm options")
			helpers.eq(root, options.projectRoot)
			helpers.eq("project.settings", options.settingsModule)
			helpers.ok(type(options.pythonPath) == "string", "expected a concrete interpreter path")
		end)
	end)

	helpers.it("skips the injection outside a project", function()
		config.setup({})

		helpers.with_cwd("/tmp", function()
			helpers.eq(nil, lsp.django_orm_options())

			local preset = lsp.pogo_config()
			helpers.eq(nil, preset.init_options)
		end)
	end)

	helpers.it("writes the pogo log inside the cache directory", function()
		local path = lsp.log_path()

		helpers.contains(path, "django.nvim")
		helpers.contains(path, "pogo.log")
	end)

	helpers.it("does not start a preset whose executable is missing", function()
		config.setup({ lsp = { ty = { enabled = true }, pogo = { enabled = true } } })

		local installed = lsp.is_installed
		lsp.is_installed = function()
			return false
		end

		local notified = {}
		local notify = vim.notify
		vim.notify = function(message, level)
			table.insert(notified, { message = message, level = level })
		end

		local enabled = lsp.setup()

		lsp.is_installed = installed
		vim.notify = notify

		helpers.eq(false, enabled.ty)
		helpers.eq(false, enabled.pogo)
		helpers.eq(2, #notified)
		helpers.contains(notified[1].message, "ty")
		helpers.contains(notified[2].message, "pogo")
	end)

	helpers.it("registers an enabled preset", function()
		config.setup({ lsp = { ty = { enabled = true } } })

		local installed = lsp.is_installed
		lsp.is_installed = function()
			return true
		end

		local started = lsp.setup_ty()

		lsp.is_installed = installed
		vim.lsp.enable("ty", false)

		helpers.eq(true, started)
		helpers.eq({ "ty", "server" }, vim.lsp.config["ty"].cmd)
	end)

	helpers.it("reports the preset state", function()
		local health = require("django.health")

		config.setup({})
		helpers.eq("preset disabled", health.__preset_state("pogo"))

		config.setup({ lsp = { pogo = { enabled = true } } })
		helpers.eq("preset enabled", health.__preset_state("pogo"))
	end)

	config.setup({})
end)

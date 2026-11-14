local helpers = require("helpers")
local manage = require("django.manage")
local utils = require("django.utils")
local config = require("django.config")

local this_file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this_file, ":p:h:h:h")

helpers.describe("manage", function()
	helpers.it("exposes the expected commands", function()
		helpers.ok(#manage.commands >= 6, "expected at least six commands")

		local seen = {}
		for _, command in ipairs(manage.commands) do
			helpers.matches(command.name, "^Django%u")
			helpers.ok(type(command.args) == "table" and #command.args > 0, "args for " .. command.name)
			helpers.ok(type(command.desc) == "string" and command.desc ~= "", "desc for " .. command.name)
			helpers.ok(not seen[command.name], "duplicate command " .. command.name)
			seen[command.name] = true
		end
	end)

	helpers.it("builds a uv command with an absolute manage.py path", function()
		config.setup({})
		helpers.with_cwd(root, function()
			local command, err = manage.build_command({ "migrate" })
			helpers.eq(nil, err)
			helpers.contains(command, vim.fn.shellescape(root .. "/manage.py"))

			if utils.is_uv_project(root) then
				helpers.contains(command, "'uv' 'run' '--quiet' 'python'")
			end

			helpers.contains(command, vim.fn.shellescape("migrate"))
		end)
	end)

	helpers.it("uses the configured interpreter", function()
		config.setup({ python = { "/custom/python" } })
		helpers.with_cwd(root, function()
			local command = manage.build_command({ "check" })
			local escaped = vim.fn.shellescape("/custom/python")
			helpers.eq(escaped, command:sub(1, #escaped))
		end)
		config.setup({})
	end)

	helpers.it("escapes arguments containing spaces", function()
		config.setup({})
		helpers.with_cwd(root, function()
			local command = manage.build_command({ "a b" })
			helpers.contains(command, vim.fn.shellescape("a b"))
		end)
	end)

	helpers.it("keeps each argument as a single token", function()
		config.setup({})
		helpers.with_cwd(root, function()
			local command = manage.build_command({ "test", "project.blog" })
			helpers.contains(command, vim.fn.shellescape("test") .. " " .. vim.fn.shellescape("project.blog"))
		end)
	end)

	helpers.it("fails outside a Django project", function()
		config.setup({})
		helpers.with_cwd("/tmp", function()
			local command, err = manage.build_command({ "check" })
			helpers.eq(nil, command)
			helpers.ok(type(err) == "string" and err ~= "", "expected an error message")
		end)
	end)

	helpers.it("ships a manage config default", function()
		config.setup({})
		helpers.eq("right", config.current.manage.position)
		helpers.eq(false, config.current.manage.auto_close)
	end)

	helpers.it("run() launches a terminal at the project root", function()
		config.setup({})

		local calls = {}
		package.loaded["snacks"] = {
			terminal = {
				toggle = function(command, opts)
					table.insert(calls, { command = command, opts = opts })
				end,
			},
		}

		local ok, err = pcall(function()
			helpers.with_cwd(root, function()
				local command = manage.run({ "check" })

				helpers.ok(command ~= nil, "expected a command")
				helpers.eq(1, #calls)
				helpers.eq(root, calls[1].opts.cwd)
				helpers.eq("right", calls[1].opts.win.position)
				helpers.eq(false, calls[1].opts.auto_close)
				helpers.contains(calls[1].command, vim.fn.shellescape("check"))
			end)
		end)

		package.loaded["snacks"] = nil

		if not ok then
			error(err, 0)
		end
	end)

	helpers.it("run() honours per-call terminal options", function()
		config.setup({})

		local calls = {}
		package.loaded["snacks"] = {
			terminal = {
				toggle = function(command, opts)
					table.insert(calls, { command = command, opts = opts })
				end,
			},
		}

		local ok, err = pcall(function()
			helpers.with_cwd(root, function()
				manage.run({ "runserver" }, { position = "bottom", auto_close = true })
				helpers.eq("bottom", calls[1].opts.win.position)
				helpers.eq(true, calls[1].opts.auto_close)
			end)
		end)

		package.loaded["snacks"] = nil

		if not ok then
			error(err, 0)
		end
	end)
end)

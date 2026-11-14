if vim.g.loaded_django_nvim then
	return
end
vim.g.loaded_django_nvim = true

vim.api.nvim_create_user_command("DjangoViews", function()
	require("django.pickers.views").show()
end, {})

vim.api.nvim_create_user_command("DjangoViewsRefresh", function()
	require("django.pickers.views").refresh()
end, {})

vim.api.nvim_create_user_command("DjangoModels", function()
	require("django.pickers.models").show()
end, {})

vim.api.nvim_create_user_command("DjangoModelsRefresh", function()
	require("django.pickers.models").refresh()
end, {})

vim.api.nvim_create_user_command("DjangoCompletionsRefresh", function()
	require("django.completions").refresh()
end, {})

vim.api.nvim_create_user_command("DjangoRefreshAll", function()
	require("django").refresh_all()
end, {})

vim.api.nvim_create_user_command("DjangoClearAllCache", function()
	require("django").clear_all_cache()
end, {})

vim.api.nvim_create_user_command("DjangoShell", function()
	require("django.shell").toggle()
end, {})

vim.api.nvim_create_user_command("DjangoShellClose", function()
	require("django.shell").close()
end, {})

vim.api.nvim_create_user_command("DjangoDoctor", function()
	require("django.health").open_report()
end, { desc = "Diagnose the django.nvim environment" })

for _, command in ipairs(require("django.manage").commands) do
	vim.api.nvim_create_user_command(command.name, function(opts)
		local args = vim.deepcopy(command.args)
		vim.list_extend(args, opts.fargs or {})
		require("django.manage").run(args)
	end, { nargs = command.nargs or 0, desc = command.desc })
end

vim.api.nvim_create_user_command("DjangoManage", function(opts)
	local args = opts.fargs or {}
	if #args == 0 then
		vim.notify("Usage: :DjangoManage <manage.py args>", vim.log.levels.WARN)
		return
	end
	require("django.manage").run(args)
end, { nargs = "*", desc = "Run a manage.py command" })

local keymaps = {
	{
		key = "<leader>Djv",
		mode = "n",
		action = function()
			require("django.pickers.views").show()
		end,
		desc = "Django Views",
		icon = "󰖟",
	},
	{
		key = "<leader>Djm",
		mode = "n",
		action = function()
			require("django.pickers.models").show()
		end,
		desc = "Django Models",
		icon = "󰆼",
	},
	{
		key = "<leader>Djr",
		mode = "n",
		action = function()
			require("django").refresh_all()
		end,
		desc = "Django Refresh All",
		icon = "󰑓",
	},
	{
		key = "<leader>Djc",
		mode = "n",
		action = function()
			require("django").clear_all_cache()
		end,
		desc = "Django Clear All Cache",
		icon = "󰃨",
	},
	{
		key = "<leader>Djs",
		mode = "n",
		action = function()
			require("django.shell").toggle()
		end,
		desc = "Django Shell",
		icon = "",
	},
	{
		key = "<leader>Djs",
		mode = "v",
		action = function()
			require("django.shell").send_selection()
		end,
		desc = "Django Shell: Send Selection",
		icon = "",
	},
}

for _, map in ipairs(keymaps) do
	vim.keymap.set(map.mode or "n", map.key, map.action, { desc = map.desc })
end

local ok, which_key = pcall(require, "which-key")
if ok then
	local wk_mappings = {
		{ "<leader>Dj", group = "django.nvim", icon = "" },
	}
	for _, map in ipairs(keymaps) do
		table.insert(wk_mappings, { map.key, desc = map.desc, icon = map.icon, mode = map.mode })
	end
	which_key.add(wk_mappings)
end

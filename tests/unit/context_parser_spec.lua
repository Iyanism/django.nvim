local helpers = require("helpers")
local ModelData = require("django.completions.core.model_data")
local context_parser = require("django.completions.core.context_parser")
local ts_context = require("django.completions.core.ts_context")
local utils = require("django.utils")

--- Minimal runtime schema
--- @return table
local function fixture()
	return {
		models = {
			Post = {
				app_label = "blog",
				module = "blog.models",
				pk = "id",
				fields = {
					id = { type = "AutoField", definition = "id = models.AutoField()" },
					title = { type = "CharField", definition = "title = models.CharField()" },
				},
			},
		},
		lookups = { base = { "exact" }, by_type = { CharField = { "icontains" } }, metadata = {} },
	}
end

--- Create a scratch buffer with python code
--- @param lines string[]
--- @return number
local function buffer(lines)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	return bufnr
end

local function skip_without_parser()
	if not utils.has_treesitter_parser("python") then
		helpers.skip("the python parser is not installed")
	end
end

helpers.describe("context_parser", function()
	ModelData.set_instance(fixture())

	helpers.it("resolves the model from the syntax tree", function()
		skip_without_parser()
		local bufnr = buffer({ "Post.objects.filter(tit" })
		local parsed = context_parser.parse(bufnr, 0, #"Post.objects.filter(tit")

		helpers.ok(parsed ~= nil, "expected a context")
		helpers.eq("Post", parsed.model_name)
		helpers.eq("filter", parsed.method)
		helpers.eq("tit", parsed.prefix)
		helpers.eq("bare", parsed.arg_kind)
		helpers.eq("treesitter", parsed.source)
	end)

	helpers.it("knows which models exist", function()
		helpers.eq(true, context_parser.is_known_model("Post"))
		helpers.eq(false, context_parser.is_known_model("Ghost"))
	end)

	helpers.it("asks for hover only on queryset receivers", function()
		skip_without_parser()

		local cases = {
			{ { "Ghost.objects.filter(" }, true, "manager of an unknown model" },
			{ { "self.get_queryset().filter(" }, true, "view helper" },
			{ { "qs = get_queryset()", "qs.filter(" }, true, "assigned queryset" },
			{ { "print(" }, false, "plain function call" },
			{ { "df.head(" }, false, "dataframe call" },
		}

		for _, case in ipairs(cases) do
			local lines = case[1]
			local row = #lines - 1
			local bufnr = buffer(lines)
			local shape = ts_context.analyze(bufnr, row, #lines[#lines])
			local wanted = shape ~= nil and context_parser.__wants_hover(bufnr, shape) or false

			helpers.eq(case[2], wanted, case[3])
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	ModelData.clear()
end)

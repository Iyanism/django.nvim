local helpers = require("helpers")
local ModelData = require("django.completions.core.model_data")
local ts_context = require("django.completions.core.ts_context")
local utils = require("django.utils")

--- Minimal runtime schema used to follow instance relations
--- @return ModelData
local function fixture()
	return ModelData.new({
		models = {
			Post = {
				app_label = "blog",
				pk = "id",
				fields = {
					id = { type = "AutoField" },
					title = { type = "CharField" },
					author = { type = "ForeignKey", related_model = "User" },
					comments = { type = "ManyToOneRel", related_model = "Comment" },
				},
			},
			User = {
				app_label = "auth",
				pk = "id",
				fields = { id = { type = "AutoField" }, username = { type = "CharField" } },
			},
			Comment = {
				app_label = "blog",
				pk = "id",
				fields = { id = { type = "AutoField" }, content = { type = "TextField" } },
			},
		},
		lookups = { base = { "exact" }, by_type = {} },
	})
end

--- Resolve a context for a single line of code
--- @param code string
--- @param col number|nil Cursor column (defaults to the end of the line)
--- @param model_data ModelData|nil
--- @return DjangoOrmContext|nil
local function resolve(code, col, model_data)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { code })
	return ts_context.resolve(bufnr, 0, col or #code, model_data)
end

--- Resolve a context for a multi line buffer
--- @param lines string[]
--- @param row number
--- @param col number
--- @param model_data ModelData|nil
--- @return DjangoOrmContext|nil
local function resolve_lines(lines, row, col, model_data)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	return ts_context.resolve(bufnr, row, col, model_data)
end

--- Analyse the syntax of a multi line buffer without resolving the model
--- @param lines string[]
--- @param row number
--- @param col number
--- @return DjangoOrmContext|nil
local function analyze_lines(lines, row, col)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	return ts_context.analyze(bufnr, row, col)
end

local function skip_without_parser()
	if not utils.has_treesitter_parser("python") then
		helpers.skip("the python parser is not installed")
	end
end

helpers.describe("ts_context", function()
	helpers.it("resolves a half typed call", function()
		skip_without_parser()
		local context = resolve("Post.objects.filter(tit")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Post", context.model_name)
		helpers.eq("filter", context.method)
		helpers.eq("tit", context.prefix)
		helpers.eq("bare", context.arg_kind)
	end)

	helpers.it("does not complete the value of a keyword argument", function()
		skip_without_parser()
		helpers.eq(nil, resolve("Post.objects.filter(title="))
		helpers.eq(nil, resolve('Post.objects.filter(title="'))
		helpers.eq(nil, resolve('Post.objects.filter(title="x"'))
	end)

	helpers.it("resolves a trailing separator", function()
		skip_without_parser()
		local context = resolve("Post.objects.filter(title__")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("title__", context.prefix)
	end)

	helpers.it("resolves a nested path", function()
		skip_without_parser()
		local context = resolve("Post.objects.filter(author__username__iexa")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("author__username__iexa", context.prefix)
	end)

	helpers.it("resolves a chained call", function()
		skip_without_parser()
		local context = resolve('Comment.objects.filter(post__title__icontains="a").exclude(stat')
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Comment", context.model_name)
		helpers.eq("exclude", context.method)
		helpers.eq("stat", context.prefix)
	end)

	helpers.it("resolves a queryset chained on a manager call", function()
		skip_without_parser()
		local context = resolve("Post.objects.all().filter(tit")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Post", context.model_name)
		helpers.eq("filter", context.method)
	end)

	helpers.it("resolves a Q object argument", function()
		skip_without_parser()
		local context = resolve('Post.objects.filter(Q(tit')
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Post", context.model_name)
		helpers.eq("filter", context.method)
		helpers.eq("tit", context.prefix)
	end)

	helpers.it("resolves write methods", function()
		skip_without_parser()
		local context = resolve("Post.objects.create(tit")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("create", context.method)
		helpers.eq("tit", context.prefix)
	end)

	helpers.it("resolves an empty argument list", function()
		skip_without_parser()
		local context = resolve("Post.objects.filter(")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Post", context.model_name)
		helpers.eq("filter", context.method)
		helpers.eq("", context.prefix)
	end)

	helpers.it("does not complete after a value", function()
		skip_without_parser()
		local context = resolve('Post.objects.filter(title__icontains="x"')
		helpers.eq(nil, context)
	end)

	helpers.it("resolves a string argument", function()
		skip_without_parser()
		local context = resolve('Post.objects.select_related("author')
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("select_related", context.method)
		helpers.eq("string", context.arg_kind)
	end)

	helpers.it("resolves a positional identifier argument", function()
		skip_without_parser()
		local context = resolve("Post.objects.values_list(tit")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("values_list", context.method)
		helpers.eq("tit", context.prefix)
	end)

	helpers.it("resolves a multi line call", function()
		skip_without_parser()
		local context = resolve_lines({
			"Post.objects.filter(",
			"    author__username__icontains",
		}, 1, #"    author__username__icontains")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Post", context.model_name)
		helpers.eq("filter", context.method)
		helpers.eq("author__username__icontains", context.prefix)
	end)

	helpers.it("resolves a call inside a class body", function()
		skip_without_parser()
		local lines = {
			"class ProbeView(ListView):",
			"    model = Post",
			"",
			"    def get_context_data(self, **kwargs):",
			"        qs = self.get_queryset().filter(tit",
		}
		local context = analyze_lines(lines, 4, #lines[5])
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("filter", context.method)
		helpers.eq("tit", context.prefix)
	end)

	helpers.it("resolves a call inside a loop header", function()
		skip_without_parser()
		local code = "for post in Post.objects.filter(tit"
		local context = resolve(code)
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("filter", context.method)
		helpers.eq("tit", context.prefix)
	end)

	helpers.it("ignores previous arguments", function()
		skip_without_parser()
		local context = resolve("Post.objects.filter(a=1, ")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("", context.prefix)
		helpers.eq("bare", context.arg_kind)
	end)

	helpers.it("ignores commas inside earlier strings", function()
		skip_without_parser()
		local context = resolve("Post.objects.filter(a='x,y', tit")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("tit", context.prefix)
	end)

	helpers.it("resolves a second string argument", function()
		skip_without_parser()
		local context = resolve('Post.objects.select_related("author", "')
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("string", context.arg_kind)
		helpers.eq("", context.prefix)
	end)

	helpers.it("returns nothing outside a call", function()
		skip_without_parser()
		helpers.eq(nil, resolve("Post.objects.filter"))
		helpers.eq(nil, resolve("x = 1"))
	end)

	helpers.it("resolves an import alias", function()
		skip_without_parser()
		local context = resolve_lines({
			"from blog.models import Post as P",
			"P.objects.filter(tit",
		}, 1, #"P.objects.filter(tit")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Post", context.model_name)
		helpers.eq("filter", context.method)
	end)

	helpers.it("resolves a plain import", function()
		skip_without_parser()
		local context = resolve_lines({
			"from blog.models import Post",
			"Post.objects.filter(tit",
		}, 1, #"Post.objects.filter(tit")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Post", context.model_name)
	end)

	helpers.it("resolves a queryset variable", function()
		skip_without_parser()
		local context = resolve_lines({
			"qs = Post.objects.all()",
			"qs.filter(tit",
		}, 1, #"qs.filter(tit")
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Post", context.model_name)
		helpers.eq("filter", context.method)
	end)

	helpers.it("ignores variables from another scope", function()
		skip_without_parser()
		local context = resolve_lines({
			"def other():",
			"    qs = Comment.objects.all()",
			"def handler(self):",
			"    qs.filter(title=",
		}, 3, #"    qs.filter(title=")
		if context then
			helpers.ok(context.model_name ~= "Comment", "must not resolve across scopes")
		end
	end)

	helpers.it("follows an instance relation", function()
		skip_without_parser()
		local context = resolve_lines({
			"post = Post.objects.get(pk=1)",
			"post.comments.filter(tit",
		}, 1, #"post.comments.filter(tit", fixture())
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Comment", context.model_name)
		helpers.eq("filter", context.method)
	end)

	helpers.it("follows a relation behind a queryset call", function()
		skip_without_parser()
		local context = resolve("Post.objects.get(pk=1).comments.filter(tit", nil, fixture())
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Comment", context.model_name)
	end)

	helpers.it("follows a relation chain", function()
		skip_without_parser()
		local context = resolve("Post.objects.filter(pk=1).first().comments.filter(tit", nil, fixture())
		helpers.ok(context ~= nil, "expected a context")
		helpers.eq("Comment", context.model_name)
		helpers.eq("filter", context.method)
	end)

	helpers.it("rejects chains that leave the ORM", function()
		skip_without_parser()
		helpers.eq(nil, resolve("Post.objects.get(pk=1).title.filter(tit", nil, fixture()))
	end)

	helpers.it("keeps self unresolved", function()
		skip_without_parser()
		local context = resolve("self.objects.filter(title=")
		if context then
			helpers.eq("self", context.model_name)
		end
	end)
end)

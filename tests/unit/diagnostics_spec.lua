local helpers = require("helpers")
local ModelData = require("django.completions.core.model_data")
local orm = require("django.diagnostics.orm")
local utils = require("django.utils")

--- Runtime schema fixture
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
					status = { type = "CharField", definition = "status = models.CharField()" },
					author = {
						type = "ForeignKey",
						definition = "author = models.ForeignKey(User)",
						related_model = "User",
					},
					tags = {
						type = "ManyToManyField",
						definition = "tags = models.ManyToManyField(Tag)",
						related_model = "Tag",
					},
					comments = {
						type = "ManyToOneRel",
						definition = "post = models.ForeignKey(Post)",
						related_model = "Comment",
					},
				},
			},
			User = {
				app_label = "auth",
				module = "auth.models",
				pk = "id",
				fields = {
					id = { type = "AutoField", definition = "id = models.AutoField()" },
					username = { type = "CharField", definition = "username = models.CharField()" },
					profile = {
						type = "OneToOneField",
						definition = "profile = models.OneToOneField(Profile)",
						related_model = "Profile",
					},
				},
			},
			Profile = {
				app_label = "auth",
				module = "auth.models",
				pk = "id",
				fields = {
					id = { type = "AutoField", definition = "id = models.AutoField()" },
					bio = { type = "TextField", definition = "bio = models.TextField()" },
				},
			},
			Tag = {
				app_label = "blog",
				module = "blog.models",
				pk = "id",
				fields = {
					id = { type = "AutoField", definition = "id = models.AutoField()" },
					name = { type = "CharField", definition = "name = models.CharField()" },
				},
			},
			Comment = {
				app_label = "blog",
				module = "blog.models",
				pk = "id",
				fields = {
					id = { type = "AutoField", definition = "id = models.AutoField()" },
					content = { type = "TextField", definition = "content = models.TextField()" },
				},
			},
		},
		lookups = {
			base = { "exact", "isnull", "in" },
			by_type = { CharField = { "iexact", "contains", "icontains" } },
			metadata = {},
		},
	}
end

--- Collect diagnostics for a code snippet
--- @param lines string[]
--- @return vim.Diagnostic[]
local function check(lines)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	local diagnostics = orm.collect(bufnr)
	vim.api.nvim_buf_delete(bufnr, { force = true })
	return diagnostics
end

--- Collect diagnostics for a single line
--- @param line string
--- @return vim.Diagnostic[]
local function check_line(line)
	return check({ line })
end

local function skip_without_parser()
	if not utils.has_treesitter_parser("python") then
		helpers.skip("the python parser is not installed")
	end
end

helpers.describe("diagnostics", function()
	ModelData.set_instance(fixture())

	helpers.it("accepts valid paths", function()
		skip_without_parser()
		helpers.eq({}, check_line("Post.objects.filter(title='x')"))
		helpers.eq({}, check_line("Post.objects.filter(title__icontains='x', author__username='y')"))
		helpers.eq({}, check_line("Post.objects.filter(pk=1)"))
	end)

	helpers.it("reports unknown path segments", function()
		skip_without_parser()
		local diagnostics = check_line("Post.objects.filter(titel='x')")

		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.unknown_segment, diagnostics[1].code)
		helpers.contains(diagnostics[1].message, "titel")
		helpers.eq(0, diagnostics[1].lnum)
		helpers.eq(20, diagnostics[1].col)
		helpers.eq(25, diagnostics[1].end_col)
	end)

	helpers.it("reports unknown segments of related models", function()
		skip_without_parser()
		local diagnostics = check_line("Post.objects.filter(author__usernam='x')")

		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.unknown_segment, diagnostics[1].code)
		helpers.contains(diagnostics[1].message, "usernam")
		helpers.contains(diagnostics[1].message, "User")
	end)

	helpers.it("reports unsupported lookups", function()
		skip_without_parser()
		local diagnostics = check_line("Post.objects.filter(title__bogus='x')")

		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.invalid_lookup, diagnostics[1].code)
		helpers.contains(diagnostics[1].message, "bogus")
	end)

	helpers.it("reports traversal through a non relation", function()
		skip_without_parser()
		local diagnostics = check_line("Post.objects.filter(title__status='x')")

		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.non_relation_traversal, diagnostics[1].code)
		helpers.contains(diagnostics[1].message, "title")
		helpers.contains(diagnostics[1].message, "status")
	end)

	helpers.it("reports lookups on write methods", function()
		skip_without_parser()
		local diagnostics = check_line("Post.objects.update(title__icontains='x')")

		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.invalid_lookup, diagnostics[1].code)
	end)

	helpers.it("accepts fields on write methods", function()
		skip_without_parser()
		helpers.eq({}, check_line("Post.objects.update(title='x')"))
		helpers.eq({}, check_line("Post.objects.create(title='x')"))
	end)

	helpers.it("checks string arguments", function()
		skip_without_parser()
		local diagnostics = check_line('Post.objects.values("titl")')

		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.unknown_segment, diagnostics[1].code)
		helpers.eq(21, diagnostics[1].col)
		helpers.eq(25, diagnostics[1].end_col)
	end)

	helpers.it("checks order_by with a descending prefix", function()
		skip_without_parser()
		local diagnostics = check_line('Post.objects.order_by("-titl")')

		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.unknown_segment, diagnostics[1].code)
		helpers.eq(24, diagnostics[1].col)
		helpers.eq(28, diagnostics[1].end_col)
	end)

	helpers.it("accepts order_by paths", function()
		skip_without_parser()
		helpers.eq({}, check_line('Post.objects.order_by("-title", "author__username")'))
	end)

	helpers.it("reports invalid select_related targets", function()
		skip_without_parser()
		local many_to_many = check_line('Post.objects.select_related("tags")')
		helpers.eq(1, #many_to_many)
		helpers.eq(orm.CODES.invalid_select_related, many_to_many[1].code)

		local plain_field = check_line('Post.objects.select_related("title")')
		helpers.eq(1, #plain_field)
		helpers.eq(orm.CODES.invalid_select_related, plain_field[1].code)
	end)

	helpers.it("accepts select_related relations", function()
		skip_without_parser()
		helpers.eq({}, check_line('Post.objects.select_related("author")'))
		helpers.eq({}, check_line('Post.objects.select_related("author__profile")'))
	end)

	helpers.it("rejects select_related paths that end on a field", function()
		skip_without_parser()
		local diagnostics = check_line('Post.objects.select_related("author__username")')

		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.invalid_select_related, diagnostics[1].code)
	end)

	helpers.it("reports prefetch_related targets that are not relations", function()
		skip_without_parser()
		local diagnostics = check_line('Post.objects.prefetch_related("title")')

		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.non_relation_traversal, diagnostics[1].code)
	end)

	helpers.it("accepts prefetch_related relations", function()
		skip_without_parser()
		helpers.eq({}, check_line('Post.objects.prefetch_related("tags", "comments")'))
	end)

	helpers.it("ignores keyword arguments that are not paths", function()
		skip_without_parser()
		helpers.eq({}, check_line("Post.objects.get_or_create(defaults={'a': 1}, title='x')"))
		helpers.eq({}, check_line('Post.objects.values_list("title", flat=True)'))
		helpers.eq({}, check_line('Post.objects.annotate(num=Count("comments"))'))
		helpers.eq({}, check_line("Post.objects.filter(**{'title': 'x'})"))
	end)

	helpers.it("checks Q objects", function()
		skip_without_parser()
		local diagnostics = check_line("Post.objects.filter(Q(titel='x'))")
		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.unknown_segment, diagnostics[1].code)

		helpers.eq({}, check_line("Post.objects.filter(Q(title='x') | Q(status='y'))"))
		helpers.eq({}, check_line("Post.objects.filter(models.Q(title='x'))"))

		local combined = check_line("Post.objects.filter(Q(title='x') | Q(bogus='y'))")
		helpers.eq(1, #combined)
		helpers.eq(orm.CODES.unknown_segment, combined[1].code)
	end)

	helpers.it("ignores unknown models", function()
		skip_without_parser()
		helpers.eq({}, check_line("Ghost.objects.filter(titel='x')"))
	end)

	helpers.it("resolves queryset variables", function()
		skip_without_parser()
		local diagnostics = check({
			"qs = Post.objects.all()",
			"qs.filter(titel='x')",
		})

		helpers.eq(1, #diagnostics)
		helpers.eq(1, diagnostics[1].lnum)
	end)

	helpers.it("resolves import aliases", function()
		skip_without_parser()
		local diagnostics = check({
			"from blog.models import Post as P",
			"P.objects.filter(titel='x')",
		})

		helpers.eq(1, #diagnostics)
		helpers.eq(orm.CODES.unknown_segment, diagnostics[1].code)
	end)

	helpers.it("checks multi line calls", function()
		skip_without_parser()
		local diagnostics = check({
			"Post.objects.filter(",
			"    titel='x',",
			")",
		})

		helpers.eq(1, #diagnostics)
		helpers.eq(1, diagnostics[1].lnum)
		helpers.eq(4, diagnostics[1].col)
	end)

	helpers.it("ignores value strings", function()
		skip_without_parser()
		helpers.eq({}, check_line("Post.objects.filter(title='not a path')"))
	end)

	helpers.it("does not check interpolated strings", function()
		skip_without_parser()
		helpers.eq({}, check_line('Post.objects.values(f"{field}")'))
	end)

	helpers.it("detects an external ORM language server", function()
		helpers.eq(true, orm.__covered_by({ { name = "pogo" } }))
		helpers.eq(false, orm.__covered_by({ { name = "pyright" }, { name = "ruff" } }))
		helpers.eq(false, orm.__covered_by(nil))
	end)

	helpers.it("reports the segment range of a path", function()
		local start_col, end_col = orm.__segment_range("author__username__bogus", 2, 10)
		helpers.eq(18, start_col)
		helpers.eq(26, end_col)
	end)

	helpers.it("extracts string literals", function()
		helpers.eq({ "title", 1 }, { orm.__string_content('"title"') })
		helpers.eq({ "title", 2 }, { orm.__string_content("r'title'") })
		helpers.eq({ "title", 3 }, { orm.__string_content('"""title"""') })
		helpers.eq({ nil, 0 }, { orm.__string_content('f"{title}"') })
	end)

	ModelData.clear()
end)

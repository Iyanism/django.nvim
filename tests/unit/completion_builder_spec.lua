local helpers = require("helpers")
local ModelData = require("django.completions.core.model_data")
local builder = require("django.completions.core.completion_builder")

--- Runtime schema fixture mirroring scripts/get_completion_data.py output
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
					title = {
						type = "CharField",
						definition = "title = models.CharField(max_length=200)",
					},
					status = { type = "CharField", definition = "status = models.CharField(max_length=20)" },
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
				},
			},
			User = {
				app_label = "auth",
				module = "auth.models",
				pk = "id",
				fields = {
					id = { type = "AutoField", definition = "id = models.AutoField()" },
					username = { type = "CharField", definition = "username = models.CharField()" },
					email = { type = "EmailField", definition = "email = models.EmailField()" },
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
		},
		lookups = {
			base = { "exact", "isnull", "in" },
			by_type = {
				CharField = { "iexact", "contains", "icontains" },
				AutoField = { "gt", "gte", "lt", "lte" },
			},
			metadata = {
				exact = { description = "Exact match", sql = "WHERE column = %s" },
				icontains = { description = "Case-insensitive containment", sql = "WHERE UPPER(column) LIKE UPPER('%s%')" },
			},
		},
	}
end

--- Collect the labels of a completion list
--- @param items table[]
--- @return table<string, boolean>
local function labels(items)
	local set = {}
	for _, item in ipairs(items) do
		set[item.label] = true
	end
	return set
end

--- Find a completion item by label
--- @param items table[]
--- @param label string
--- @return table|nil
local function find(items, label)
	for _, item in ipairs(items) do
		if item.label == label then
			return item
		end
	end
	return nil
end

helpers.describe("completion_builder", function()
	ModelData.set_instance(fixture())

	helpers.it("completes keyword fields with lookups", function()
		local items = builder.build("Post", "filter", "tit", "keyword")
		local set = labels(items)
		helpers.ok(set["title"], "expected the title field")
		helpers.ok(set["title__icontains"], "expected the icontains lookup")
		helpers.ok(set["title__exact"], "expected the exact lookup")
		helpers.ok(not set["author__username"], "lookups must not be pre-expanded")
	end)

	helpers.it("completes the pk alias", function()
		local items = builder.build("Post", "filter", "", "keyword")
		local item = find(items, "pk")
		helpers.ok(item ~= nil, "expected a pk item")
		helpers.contains(item.detail, "AutoField")
		helpers.contains(item.documentation.value, "id")
	end)

	helpers.it("traverses relations", function()
		local items = builder.build("Post", "filter", "author__", "keyword")
		local set = labels(items)
		helpers.ok(set["author__username"], "expected the related username field")
		helpers.ok(set["author__username__icontains"], "expected lookups on related fields")
		helpers.ok(not set["author__title"], "must not mix in fields of the source model")
	end)

	helpers.it("completes lookups on a terminal field", function()
		local items = builder.build("Post", "filter", "title__", "keyword")
		local set = labels(items)
		helpers.ok(set["title__icontains"], "expected a lookup")
		helpers.ok(not set["title__title"], "expected no field completion after a terminal field")
	end)

	helpers.it("returns nothing for an unknown path", function()
		helpers.eq({}, builder.build("Post", "filter", "adress__", "keyword"))
	end)

	helpers.it("completes string arguments without lookups", function()
		local items = builder.build("Post", "values", "", "string")
		local set = labels(items)
		helpers.ok(set["title"], "expected the title field")
		helpers.ok(set["author"], "expected the forward relation")
		helpers.ok(not set["title__icontains"], "values() takes field names, not lookups")
	end)

	helpers.it("keeps keyword arguments keyword even for string methods", function()
		local items = builder.build("Post", "values", "tit", "keyword")
		helpers.ok(labels(items)["title"], "expected the title field")
	end)

	helpers.it("ignores value strings", function()
		helpers.eq({}, builder.build("Post", "filter", "", "string"))
	end)

	helpers.it("ignores positional arguments of keyword methods", function()
		helpers.eq({}, builder.build("Post", "filter", "", "positional"))
	end)

	helpers.it("completes select_related with relations only", function()
		local items = builder.build("Post", "select_related", "", "string")
		local set = labels(items)
		helpers.ok(set["author"], "expected the forward relation")
		helpers.ok(not set["title"], "select_related must not offer plain fields")
		helpers.ok(not set["tags"], "select_related cannot follow many to many relations")
	end)

	helpers.it("completes prefetch_related with every relation", function()
		local set = labels(builder.build("Post", "prefetch_related", "", "string"))
		helpers.ok(set["author"], "expected the forward relation")
		helpers.ok(set["tags"], "expected the many to many relation")
	end)

	helpers.it("falls back to the method style without an argument kind", function()
		local set = labels(builder.build("Post", "order_by", "", nil))
		helpers.ok(set["title"], "expected the title field")
		helpers.ok(not set["title__icontains"], "order_by takes field names only")
	end)

	helpers.it("completes the newest and oldest shortcuts", function()
		helpers.ok(labels(builder.build("Post", "latest", "", "string"))["title"], "expected latest fields")
		helpers.ok(labels(builder.build("Post", "earliest", "", "string"))["title"], "expected earliest fields")
	end)

	helpers.it("returns nothing for an unknown method", function()
		helpers.eq({}, builder.build("Post", "exists", "", "keyword"))
	end)

	helpers.it("returns nothing for an unknown model", function()
		helpers.eq({}, builder.build("Ghost", "filter", "", "keyword"))
	end)

	helpers.it("sorts items deterministically", function()
		local first = builder.build("Post", "values", "", "string")
		local second = builder.build("Post", "values", "", "string")
		helpers.eq(labels(first), labels(second))
		helpers.eq(first[1].label, second[1].label)
	end)

	ModelData.clear()
end)

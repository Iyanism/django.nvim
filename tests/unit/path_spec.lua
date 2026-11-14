local helpers = require("helpers")
local path = require("django.completions.core.path")

--- Minimal ModelData stub for path resolution
--- @return table
local function make_model_data()
	local models = {
		Post = {
			app_label = "blog",
			module = "blog.models",
			pk = "id",
			fields = {
				id = { type = "AutoField", definition = "id = models.AutoField()" },
				title = { type = "CharField", definition = "title = models.CharField(max_length=200)" },
				views = { type = "IntegerField", definition = "views = models.IntegerField()" },
				author = {
					type = "ForeignKey",
					definition = "author = models.ForeignKey(User)",
					related_model = "User",
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
				email = { type = "EmailField", definition = "email = models.EmailField()" },
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
	}

	local lookups = {
		base = { "exact", "isnull", "in" },
		by_type = {
			CharField = { "iexact", "contains", "icontains", "startswith" },
			TextField = { "iexact", "contains", "icontains" },
			EmailField = { "iexact", "contains", "icontains" },
			IntegerField = { "gt", "gte", "lt", "lte" },
			AutoField = { "gt", "gte", "lt", "lte" },
		},
		metadata = {},
	}

	local ModelData = {}
	ModelData.__index = ModelData

	function ModelData:get_model(name)
		return models[name]
	end

	function ModelData:get_field(model_name, field_name)
		local model = models[model_name]
		if not model then
			return nil
		end
		return model.fields[field_name]
	end

	function ModelData:get_pk(model_name)
		local model = models[model_name]
		return model and model.pk or nil
	end

	function ModelData:get_lookups_for_type(field_type)
		local result = vim.list_extend({}, lookups.base)
		for _, lookup in ipairs(lookups.by_type[field_type] or {}) do
			table.insert(result, lookup)
		end
		return result
	end

	function ModelData:is_lookup(lookup, field_type)
		return vim.tbl_contains(self:get_lookups_for_type(field_type), lookup)
	end

	return setmetatable({ models = models, lookups = lookups }, ModelData)
end

helpers.describe("path", function()
	local model_data = make_model_data()

	helpers.it("splits paths on double underscores only", function()
		helpers.eq({ "author", "username" }, path.split("author__username"))
		helpers.eq({ "author_id" }, path.split("author_id"))
		helpers.eq({ "title", "" }, path.split("title__"))
		helpers.eq({}, path.split(""))
		helpers.eq({}, path.split(nil))
	end)

	helpers.it("resolves a plain field", function()
		local result = path.resolve("Post", { "title" }, model_data)
		helpers.eq(true, result.ok)
		helpers.eq("title", result.field_name)
		helpers.eq("Post", result.field_model)
		helpers.eq(nil, result.model)
	end)

	helpers.it("follows a relation", function()
		local result = path.resolve("Post", { "author" }, model_data)
		helpers.eq(true, result.ok)
		helpers.eq("User", result.model)
		helpers.eq("author", result.field_name)
		helpers.eq("ForeignKey", result.field.type)
	end)

	helpers.it("follows a reverse relation", function()
		local result = path.resolve("Post", { "comments" }, model_data)
		helpers.eq(true, result.ok)
		helpers.eq("Comment", result.model)
	end)

	helpers.it("resolves a nested field", function()
		local result = path.resolve("Post", { "author", "username" }, model_data)
		helpers.eq(true, result.ok)
		helpers.eq("username", result.field_name)
		helpers.eq("User", result.field_model)
	end)

	helpers.it("resolves a lookup on a terminal field", function()
		local result = path.resolve("Post", { "title", "icontains" }, model_data)
		helpers.eq(true, result.ok)
		helpers.eq("icontains", result.lookup)
		helpers.eq("title", result.field_name)
	end)

	helpers.it("resolves a lookup on a nested field", function()
		local result = path.resolve("Post", { "author", "username", "iexact" }, model_data)
		helpers.eq(true, result.ok)
		helpers.eq("iexact", result.lookup)
		helpers.eq("User", result.field_model)
	end)

	helpers.it("accepts base lookups on relations", function()
		local result = path.resolve("Post", { "author", "isnull" }, model_data)
		helpers.eq(true, result.ok)
		helpers.eq("isnull", result.lookup)
	end)

	helpers.it("resolves the pk alias", function()
		local result = path.resolve("Post", { "pk" }, model_data)
		helpers.eq(true, result.ok)
		helpers.eq("id", result.field_name)
		helpers.eq("Post", result.field_model)
	end)

	helpers.it("resolves the pk alias of a related model", function()
		local result = path.resolve("Post", { "author", "pk" }, model_data)
		helpers.eq(true, result.ok)
		helpers.eq("id", result.field_name)
		helpers.eq("User", result.field_model)
	end)

	helpers.it("reports unknown fields", function()
		local result = path.resolve("Post", { "adress" }, model_data)
		helpers.eq(false, result.ok)
		helpers.eq("unknown-field", result.error.kind)
		helpers.eq("adress", result.error.segment)
		helpers.eq(1, result.error.index)
		helpers.contains(result.error.message, "adress")
	end)

	helpers.it("reports unknown fields on related models", function()
		local result = path.resolve("Post", { "author", "nope" }, model_data)
		helpers.eq(false, result.ok)
		helpers.eq("unknown-field", result.error.kind)
		helpers.eq("User", result.error.message:match("model '(%w+)'"))
	end)

	helpers.it("reports invalid lookups", function()
		local result = path.resolve("Post", { "title", "bogus" }, model_data)
		helpers.eq(false, result.ok)
		helpers.eq("invalid-lookup", result.error.kind)
		helpers.eq("bogus", result.error.segment)
		helpers.eq(2, result.error.index)
	end)

	helpers.it("keeps the partial path on failure", function()
		local result = path.resolve("Post", { "author", "nope" }, model_data)
		helpers.eq(false, result.ok)
		helpers.eq("author", result.field_name)
		helpers.eq("Post", result.field_model)
	end)

	helpers.it("reports an unknown model", function()
		local result = path.resolve("Ghost", { "title" }, model_data)
		helpers.eq(false, result.ok)
		helpers.eq("unknown-model", result.error.kind)
	end)

	helpers.it("stays silent on paths it cannot judge", function()
		local result = path.resolve("Post", { "title", "icontains", "extra" }, model_data)
		helpers.eq(true, result.ok)
	end)

	helpers.it("validates complete paths", function()
		local ok_result = path.validate("Post", "author__username__iexact", model_data)
		helpers.eq(true, ok_result.ok)

		local bad_result = path.validate("Post", "author__nope", model_data)
		helpers.eq(false, bad_result.ok)
		helpers.eq("unknown-field", bad_result.error.kind)
	end)
end)

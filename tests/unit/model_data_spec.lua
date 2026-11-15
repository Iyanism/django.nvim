local helpers = require("helpers")
local ModelData = require("django.completions.core.model_data")

--- Minimal schema with a reverse relation whose accessor differs
--- @return table
local function fixture()
	return {
		schema_version = 2,
		models = {
			Post = {
				app_label = "blog",
				module = "blog.models",
				pk = "id",
				fields = {
					id = { type = "AutoField" },
					title = { type = "CharField" },
					child = {
						type = "ManyToOneRel",
						related_model = "Child",
						query_name = "child",
						accessor_name = "child_set",
					},
				},
			},
			Child = {
				app_label = "blog",
				module = "blog.models",
				pk = "id",
				fields = { id = { type = "AutoField" } },
			},
		},
		lookups = {
			base = { "exact", "isnull" },
			by_type = {
				CharField = { "exact", "icontains", "contains" },
			},
		},
	}
end

helpers.describe("model data", function()
	helpers.it("accepts the current schema version", function()
		helpers.eq(true, ModelData.is_current(fixture()))
		helpers.eq(true, ModelData.is_current({ schema_version = 2 }))
		helpers.eq(true, ModelData.is_current({}), "unversioned fixtures stay valid")
		helpers.eq(false, ModelData.is_current({ schema_version = 1 }))
		helpers.eq(false, ModelData.is_current(nil))
	end)

	helpers.it("indexes reverse relation accessors", function()
		local data = ModelData.new(fixture())

		helpers.eq("Child", data:get_field("Post", "child").related_model)
		helpers.eq(nil, data:get_field("Post", "child_set"))
		helpers.eq("Child", data:get_accessor_field("Post", "child_set").related_model)
		helpers.eq(nil, data:get_accessor_field("Post", "child"))
	end)

	helpers.it("resolves instance fields through both names", function()
		local data = ModelData.new(fixture())

		helpers.eq("ManyToOneRel", data:get_instance_field("Post", "child").type)
		helpers.eq("ManyToOneRel", data:get_instance_field("Post", "child_set").type)
		helpers.eq("CharField", data:get_instance_field("Post", "title").type)
		helpers.eq(nil, data:get_instance_field("Post", "bogus"))
	end)

	helpers.it("merges base and type lookups without duplicates", function()
		local data = ModelData.new(fixture())
		local lookups = data:get_lookups_for_type("CharField")

		helpers.eq({ "exact", "isnull", "icontains", "contains" }, lookups)
		helpers.eq(true, data:is_lookup("icontains", "CharField"))
		helpers.eq(false, data:is_lookup("icontains", "AutoField"))
		helpers.eq(true, data:is_lookup("exact", "AutoField"))
	end)

	helpers.it("offers only base lookups for relation types", function()
		local data = ModelData.new(fixture())

		helpers.eq({ "exact", "isnull" }, data:get_lookups_for_type("ForeignKey"))
		helpers.eq(true, data:is_lookup("exact", "ForeignKey"))
		helpers.eq(false, data:is_lookup("icontains", "ForeignKey"))
	end)
end)

ModelData.clear()

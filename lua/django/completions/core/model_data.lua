---@class ChoiceValue
---@field value string|number
---@field label string

---@class ChoicesInfo
---@field values ChoiceValue[]
---@field class? string
---@field type? string

---@class FieldInfo
---@field type string
---@field definition string
---@field null boolean
---@field blank boolean
---@field max_length? number
---@field related_model? string
---@field related_app? string
---@field traversable? boolean
---@field choices? ChoicesInfo
---@field query_name? string Reverse relation name used in ORM paths
---@field accessor_name? string Reverse relation name used on instances

---@class ModelInfo
---@field app_label string
---@field module string
---@field pk string|nil Primary key field name
---@field fields table<string, FieldInfo>
---@field accessors? table<string, FieldInfo> Reverse relations by accessor name

---@class LookupMetadata
---@field description string
---@field sql string

---@class LookupData
---@field base string[]
---@field by_type table<string, string[]>
---@field metadata table<string, LookupMetadata>

---@class ModelData
---@field models table<string, ModelInfo>
---@field lookups LookupData

local ModelData = {}
ModelData.__index = ModelData

local fetcher = require("django.fetcher")

local SCRIPT_NAME = "get_completion_data.py"
local CACHE_NAME = "completions_v2"

--- Version of the JSON contract emitted by scripts/get_completion_data.py
local SCHEMA_VERSION = 2

local instance = nil

function ModelData.new(data)
	local self = setmetatable({}, ModelData)
	self.models = data.models or {}
	self.lookups = data.lookups or {}
	self.schema_version = data.schema_version
	ModelData.__index_accessors(self.models)
	return self
end

--- Whether a payload matches the current JSON contract
--- Missing versions are accepted so test fixtures stay valid.
---@param data table|nil
---@return boolean
function ModelData.is_current(data)
	if type(data) ~= "table" then
		return false
	end

	local version = data.schema_version
	return version == nil or version == SCHEMA_VERSION
end

--- Index reverse relation accessor names per model
---@param models table<string, ModelInfo>
function ModelData.__index_accessors(models)
	for _, model in pairs(models or {}) do
		local accessors = {}

		for name, field in pairs(model.fields or {}) do
			local accessor = field.accessor_name
			if accessor and accessor ~= name then
				accessors[accessor] = field
			end
		end

		model.accessors = accessors
	end
end

--- Get singleton instance (loads data if needed)
--- Must be called within async.run()
---@return ModelData|nil
function ModelData.get_instance()
	if instance then
		return instance
	end

	local data = fetcher.get_or_fetch(SCRIPT_NAME, CACHE_NAME, { silent = true })
	if not ModelData.is_current(data) then
		return nil
	end

	instance = ModelData.new(data)
	return instance
end

--- Get the schema without ever running the introspection script
--- Safe to call from synchronous contexts: an empty cache yields nil.
---@return ModelData|nil
function ModelData.peek()
	if instance then
		return instance
	end

	local data = fetcher.get_cached_data(CACHE_NAME)
	if not data or vim.tbl_isempty(data) or not ModelData.is_current(data) then
		return nil
	end

	instance = ModelData.new(data)
	return instance
end

--- Clear cached instance
function ModelData.clear()
	instance = nil
end

--- Set singleton instance (for refresh)
---@param data table
function ModelData.set_instance(data)
	if ModelData.is_current(data) then
		instance = ModelData.new(data)
	end
end

--- Get model by name
---@param model_name string
---@return ModelInfo|nil
function ModelData:get_model(model_name)
	return self.models[model_name]
end

--- Get field from model
---@param model_name string
---@param field_name string
---@return FieldInfo|nil
function ModelData:get_field(model_name, field_name)
	local model = self:get_model(model_name)
	if not model or not model.fields then
		return nil
	end
	return model.fields[field_name]
end

--- Get a reverse relation by its instance accessor name
--- Reverse relations are keyed by their ORM query name; the accessor can
--- differ (a forward field without `related_name` gives `child_set`).
---@param model_name string
---@param field_name string
---@return FieldInfo|nil
function ModelData:get_accessor_field(model_name, field_name)
	local model = self:get_model(model_name)
	if not model or not model.accessors then
		return nil
	end
	return model.accessors[field_name]
end

--- Get a field as reached from a model instance
---@param model_name string
---@param field_name string
---@return FieldInfo|nil
function ModelData:get_instance_field(model_name, field_name)
	return self:get_field(model_name, field_name) or self:get_accessor_field(model_name, field_name)
end

--- Get lookups for field type
---@param field_type string
---@return string[]
function ModelData:get_lookups_for_type(field_type)
	local result = {}
	local seen = {}

	local function add(name)
		if not seen[name] then
			seen[name] = true
			table.insert(result, name)
		end
	end

	for _, lookup in ipairs(self.lookups.base or {}) do
		add(lookup)
	end

	local type_lookups = self.lookups.by_type and self.lookups.by_type[field_type]
	if type_lookups then
		for _, lookup in ipairs(type_lookups) do
			add(lookup)
		end
	end

	return result
end

--- Check whether a name is a valid lookup for a field type
--- @param lookup string
--- @param field_type string
--- @return boolean
function ModelData:is_lookup(lookup, field_type)
	for _, name in ipairs(self:get_lookups_for_type(field_type)) do
		if name == lookup then
			return true
		end
	end

	return false
end

--- Get the primary key field name of a model
--- @param model_name string
--- @return string|nil
function ModelData:get_pk(model_name)
	local model = self:get_model(model_name)
	if not model then
		return nil
	end

	return model.pk
end

--- Get lookup metadata
---@param lookup_name string
---@return LookupMetadata|nil
function ModelData:get_lookup_metadata(lookup_name)
	if not self.lookups.metadata then
		return nil
	end
	return self.lookups.metadata[lookup_name]
end

return ModelData

--- ORM path resolution shared by completion and diagnostics.
---
--- A path is the "__" separated chain used in QuerySet keyword arguments,
--- e.g. "author__username__iexact".
---
--- The resolver is deliberately conservative: when a path cannot be judged
--- with certainty it reports success instead of raising a false error.
local M = {}

---@class DjangoPathError
---@field kind "unknown-model"|"unknown-field"|"invalid-lookup"
---@field message string
---@field segment string Offending segment
---@field index number Index of the segment inside the path (1-based)

---@class DjangoPathResult
---@field ok boolean
---@field model string|nil Model the path ends in (nil when it ends on a field)
---@field field FieldInfo|nil Terminal field
---@field field_name string|nil
---@field field_model string|nil Model owning the terminal field
---@field lookup string|nil Terminal lookup
---@field error DjangoPathError|nil
---@field segments string[] Segments that were resolved

--- Split a path into segments on the "__" separator
--- Single underscores are part of field names (author_id) and are preserved.
--- @param path string|nil
--- @return string[]
function M.split(path)
	if not path or path == "" then
		return {}
	end

	local segments = {}
	local remaining = path

	while true do
		local pos = remaining:find("__", 1, true)
		if not pos then
			break
		end
		table.insert(segments, remaining:sub(1, pos - 1))
		remaining = remaining:sub(pos + 2)
	end

	table.insert(segments, remaining)

	return segments
end

--- Resolve ORM path segments against the runtime schema
--- @param model_name string Model the path starts from
--- @param segments string[] Segments to resolve
--- @param model_data ModelData
--- @return DjangoPathResult
function M.resolve(model_name, segments, model_data)
	local result = {
		ok = true,
		model = model_name,
		segments = {},
	}

	if not model_data or not model_data:get_model(model_name) then
		return M.__fail(result, {
			kind = "unknown-model",
			message = string.format("Unknown model '%s'", tostring(model_name)),
			segment = tostring(model_name),
			index = 0,
		})
	end

	local current_model = model_name
	local last_field = nil
	local last_field_name = nil
	local last_field_model = nil

	for index, segment in ipairs(segments) do
		if segment ~= "" then
			local field = model_data:get_field(current_model, segment)
			local field_name = segment

			if not field and segment == "pk" and current_model then
				local pk_name = model_data:get_pk(current_model)
				if pk_name then
					field = model_data:get_field(current_model, pk_name)
					field_name = pk_name
				end
			end

			if field then
				table.insert(result.segments, segment)
				last_field = field
				last_field_name = field_name
				last_field_model = current_model

				if field.related_model then
					current_model = field.related_model
					result.model = current_model
				else
					current_model = nil
					result.model = nil
				end
			else
				-- The segment may still be a lookup on the previous field
				if last_field and model_data:is_lookup(segment, last_field.type) then
					table.insert(result.segments, segment)
					result.lookup = segment
					result.field = last_field
					result.field_name = last_field_name
					result.field_model = last_field_model
					return result
				end

				local kind = "unknown-field"
				if last_field and not last_field.related_model then
					kind = "invalid-lookup"
				end

				return M.__fail(result, {
					kind = kind,
					message = M.__error_message(kind, segment, last_field_name, current_model or last_field_model),
					segment = segment,
					index = index,
				})
			end
		end
	end

	-- A relation keeps the traversal open, only concrete fields terminate a path
	if last_field and not last_field.related_model then
		result.field = last_field
		result.field_name = last_field_name
		result.field_model = last_field_model
	end

	return result
end

--- Validate a complete ORM path
--- @param model_name string
--- @param path string
--- @param model_data ModelData
--- @return DjangoPathResult
function M.validate(model_name, path, model_data)
	return M.resolve(model_name, M.split(path), model_data)
end

--- Mark a result as failed
--- @param result DjangoPathResult
--- @param error DjangoPathError
--- @return DjangoPathResult
function M.__fail(result, error)
	result.ok = false
	result.error = error
	result.model = nil
	result.field = nil
	result.field_name = nil
	result.field_model = nil
	result.lookup = nil
	return result
end

--- Build a human readable error message
--- @param kind string
--- @param segment string
--- @param last_field_name string|nil
--- @param last_field_model string|nil
--- @return string
function M.__error_message(kind, segment, last_field_name, last_field_model)
	if kind == "invalid-lookup" then
		return string.format("Unsupported lookup '%s' for field '%s'", segment, last_field_name or "?")
	end

	if last_field_model then
		return string.format("Unknown field '%s' on model '%s'", segment, last_field_model)
	end

	return string.format("Unknown field '%s'", segment)
end

return M

--- Dependency-free mini test framework for headless Neovim runs.
local M = {}

M.results = {
	passed = 0,
	failed = 0,
	skipped = 0,
	failures = {},
}

local ctx = {
	group = "",
	name = "",
}

--- Format a value for assertion messages
--- @param value any
--- @return string
local function fmt_value(value)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return (vim.inspect(value):gsub("\n%s*", " "))
end

--- Capture the call site of an assertion
--- @return string
local function loc()
	local info = debug.getinfo(3, "Sl")
	if not info then
		return "?"
	end
	return string.format("%s:%d", info.short_src, info.currentline)
end

--- Raise an assertion failure
--- @param message string
local function fail(message)
	error({ assertion = true, message = message, location = loc() }, 0)
end

--- Start a named group of tests
--- @param name string
--- @param fn function
function M.describe(name, fn)
	local previous = ctx.group
	ctx.group = previous == "" and name or (previous .. " > " .. name)

	local ok, err = pcall(fn)
	if not ok then
		M.__record(ctx.group, "<describe>", debug.traceback(tostring(err), 2))
	end

	ctx.group = previous
end

--- Run a single test case
--- @param name string
--- @param fn function
function M.it(name, fn)
	ctx.name = name

	local ok, err = xpcall(fn, function(e)
		return e
	end)

	if ok then
		M.results.passed = M.results.passed + 1
		io.write(string.format("ok    %s > %s\n", ctx.group, name))
		return
	end

	if type(err) == "table" and err.skip then
		M.results.skipped = M.results.skipped + 1
		io.write(string.format("skip  %s > %s (%s)\n", ctx.group, name, err.reason or "skipped"))
		return
	end

	if type(err) == "table" and err.assertion then
		M.__record(ctx.group, name, err.location .. ": " .. err.message)
		return
	end

	M.__record(ctx.group, name, debug.traceback(tostring(err), 2))
end

--- Abort the current test and mark it as skipped
--- @param reason string
function M.skip(reason)
	error({ skip = true, reason = reason or "skipped" }, 0)
end

--- Assert deep equality
--- @param expected any
--- @param actual any
--- @param message string|nil
function M.eq(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		fail(
			string.format(
				"%sexpected %s, got %s",
				message and (message .. ": ") or "",
				fmt_value(expected),
				fmt_value(actual)
			)
		)
	end
end

--- Assert a truthy value
--- @param value any
--- @param message string|nil
function M.ok(value, message)
	if not value then
		fail((message or "expected a truthy value") .. ", got " .. fmt_value(value))
	end
end

M.truthy = M.ok

--- Assert a string contains a substring
--- @param haystack string
--- @param needle string
--- @param message string|nil
function M.contains(haystack, needle, message)
	if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
		fail(
			string.format(
				"%sexpected %s to contain %s",
				message and (message .. ": ") or "",
				fmt_value(haystack),
				fmt_value(needle)
			)
		)
	end
end

--- Assert a string matches a Lua pattern
--- @param text string
--- @param pattern string
--- @param message string|nil
function M.matches(text, pattern, message)
	if type(text) ~= "string" or not text:find(pattern) then
		fail(
			string.format(
				"%sexpected %s to match %s",
				message and (message .. ": ") or "",
				fmt_value(text),
				fmt_value(pattern)
			)
		)
	end
end

--- Assert a function does not raise
--- @param fn function
--- @param message string|nil
--- @return any result
function M.no_error(fn, message)
	local ok, result = pcall(fn)
	if not ok then
		fail((message and (message .. ": ") or "") .. tostring(result))
	end
	return result
end

--- Run a function with a temporary working directory
--- @param dir string
--- @param fn function
--- @return any result
function M.with_cwd(dir, fn)
	local previous = vim.fn.getcwd()
	vim.cmd("cd " .. vim.fn.fnameescape(dir))
	local ok, result = pcall(fn)
	vim.cmd("cd " .. vim.fn.fnameescape(previous))
	if not ok then
		error(result, 0)
	end
	return result
end

--- Record a failure
--- @param group string
--- @param name string
--- @param message string
function M.__record(group, name, message)
	M.results.failed = M.results.failed + 1
	table.insert(M.results.failures, {
		group = group,
		name = name,
		message = message,
	})
	io.write(string.format("FAIL  %s > %s\n", group, name))
end

--- Print the summary
--- @return boolean success
function M.summary()
	if #M.results.failures > 0 then
		io.write("\nFailures:\n")
		for _, failure in ipairs(M.results.failures) do
			io.write(string.format("  %s > %s\n    %s\n", failure.group, failure.name, failure.message))
		end
	end

	io.write(
		string.format(
			"\n%d passed, %d failed, %d skipped\n",
			M.results.passed,
			M.results.failed,
			M.results.skipped
		)
	)

	return M.results.failed == 0
end

return M

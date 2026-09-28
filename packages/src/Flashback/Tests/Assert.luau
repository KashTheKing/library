--!strict
--[=[
	@class Assert
	@ignore
	Assertion helpers passed to every test case.
]=]

export type T = {
	eq: (any, any, string?) -> (),
	near: (number, number, number, string?) -> (),
	ok: (any, string?) -> (),
	fails: (() -> ()) -> (),
}

local function describe(v: any): string
	if typeof(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local Assert: T = {
	eq = function(actual, expected, msg)
		if actual ~= expected then
			error(`{msg or "eq"}: expected {describe(expected)}, got {describe(actual)}`, 2)
		end
	end,
	near = function(actual, expected, eps, msg)
		if math.abs(actual - expected) > eps then
			error(`{msg or "near"}: expected {expected} ± {eps}, got {actual}`, 2)
		end
	end,
	ok = function(v, msg)
		if not v then
			error(`{msg or "ok"}: expected truthy, got {describe(v)}`, 2)
		end
	end,
	fails = function(fn)
		if pcall(fn) then
			error("fails: expected an error", 2)
		end
	end,
}

return Assert

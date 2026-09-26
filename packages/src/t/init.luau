-- t: a runtime typechecker for Roblox

--[=[
	@class t

	`t` is a runtime type checker for Roblox Luau. It is a fork of
	[osyrisrblx/t](https://github.com/osyrisrblx/t) published as `kashtheking/t`, with the same
	API plus checks for newer Roblox types (`buffer`, `Content`, `Font`, `FloatCurveKey`, ...).

	## Checks

	Everything in `t` is built from **checks**. A check is a function with the signature
	`(value: any) -> (boolean, string?)`: it returns `true` when the value is acceptable, or
	`false` followed by a human-readable message explaining what was wrong. Members of `t` come
	in two flavours:

	- **Plain checks** that you call directly: `t.string`, `t.number`, `t.boolean`, `t.table`,
	  `t.Instance`, `t.Vector3`, `t.CFrame`, `t.any`, `t.integer`, `t.nan`, `t.numberPositive`, ...
	- **Check constructors** that take arguments and *return* a new check, so you compose them:
	  `t.optional(t.string)`, `t.array(t.number)`, `t.numberMin(0)`, `t.literal("a", "b")`,
	  `t.interface({ ... })`, `t.tuple(...)`, `t.instanceIsA("BasePart")`.

	Because a failing check returns `false, message`, `assert(check(value))` raises that message
	as the error, which is the idiomatic way to guard arguments.

	```lua
	local t = require(path.to.t)

	local ok, err = t.number(5)   --> true
	ok, err = t.number("5")       --> false, "number expected, got string"

	-- Build checks once, at module level, and reuse them.
	local IsSaveData = t.interface({
		Level = t.numberMin(1),
		Coins = t.integer,
		Inventory = t.array(t.string),
		Nickname = t.optional(t.string),
		Team = t.literal("Red", "Blue"),
	})

	local checkSave = t.tuple(t.instanceIsA("Player"), IsSaveData)

	local function savePlayer(player, data)
		assert(checkSave(player, data))
		-- ...
	end

	-- Or let t generate the guard for you:
	local savePlayerStrict = t.wrap(savePlayer, checkSave)
	local assertSave = t.strict(checkSave) -- assertSave(player, data) errors on bad input
	```

	## Type checks

	The plain type checks are created with [t.typeof] (or [t.type] for `userdata` and `vector`)
	and simply compare the value's type name. Lua primitives: `t.boolean`, `t.buffer`, `t.thread`,
	`t.callback` (alias `t["function"]`), `t.none` (alias `t["nil"]`), `t.string`, `t.table`,
	`t.userdata`, `t.vector`, plus [t.number] (which rejects NaN) and [t.nan]. Roblox data types:
	`t.Axes`, `t.BrickColor`, `t.CatalogSearchParams`, `t.CFrame`, `t.Content`, `t.Color3`,
	`t.ColorSequence`, `t.ColorSequenceKeypoint`, `t.DateTime`, `t.DockWidgetPluginGuiInfo`,
	`t.Enum`, `t.EnumItem`, `t.Enums`, `t.Faces`, `t.FloatCurveKey`, `t.Font`, `t.Instance`,
	`t.NumberRange`, `t.NumberSequence`, `t.NumberSequenceKeypoint`, `t.OverlapParams`,
	`t.PathWaypoint`, `t.PhysicalProperties`, `t.Random`, `t.Ray`, `t.RaycastParams`,
	`t.RaycastResult`, `t.RBXScriptConnection`, `t.RBXScriptSignal`, `t.Rect`, `t.Region3`,
	`t.Region3int16`, `t.TweenInfo`, `t.UDim`, `t.UDim2`, `t.Vector2`, `t.Vector2int16`,
	`t.Vector3`, `t.Vector3int16`. Each is also listed individually below.

	## Aliases

	`t.some` = [t.union], `t.every` = [t.intersection], `t.instance` = [t.instanceOf],
	`t["function"]` = [t.callback], `t["nil"]` = [t.none], and the deprecated `t.exactly` =
	[t.literal].

	**Credits:** `t` was created by **[Osyris](https://github.com/osyrisrblx)** ([osyrisrblx/t](https://github.com/osyrisrblx/t), MIT). This build is his library published to Wally as `kashtheking/t` with checks for newer Roblox data types added by KashTheKing.

	Installation and guide: [t package page](/docs/packages/t).
]=]
local t = {}

--[=[
	@type Check (value: any) -> (boolean, string?)
	@within t
	A type check. Returns `true` if `value` is acceptable, otherwise `false` and a message that
	describes the problem. Every plain check in `t` has this signature and every check constructor
	returns one, so checks can be nested freely (`t.array(t.optional(t.number))`).
]=]
--[=[
	Returns a check that passes when Lua's `type(value)` equals `typeName`. Prefer [t.typeof] for
	anything but the raw Lua categories, because `type` reports every Roblox data type as
	`"userdata"` (and `Vector3` as `"vector"`).

	```lua
	local isUserdata = t.type("userdata")
	print(isUserdata(CFrame.new())) --> true
	```

	@function type
	@within t
	@param typeName string -- The name `type()` must return, e.g. `"userdata"`, `"vector"`, `"string"`.
	@return Check -- Fails with `"<typeName> expected, got <actual>"`.
]=]
function t.type(typeName)
	return function(value)
		local valueType = type(value)
		if valueType == typeName then
			return true
		else
			return false, string.format("%s expected, got %s", typeName, valueType)
		end
	end
end

--[=[
	Returns a check that passes when Roblox's `typeof(value)` equals `typeName`. This is how all
	the built-in type checks (`t.string`, `t.Vector3`, `t.Instance`, ...) are made, so you only
	need it for a type that has no ready-made check.

	```lua
	local isSharedTable = t.typeof("SharedTable")
	```

	@function typeof
	@within t
	@param typeName string -- The name `typeof()` must return, e.g. `"Vector3"`, `"Instance"`, `"EnumItem"`.
	@return Check -- Fails with `"<typeName> expected, got <actual>"`.
]=]
function t.typeof(typeName)
	return function(value)
		local valueType = typeof(value)
		if valueType == typeName then
			return true
		else
			return false, string.format("%s expected, got %s", typeName, valueType)
		end
	end
end

--[[**
	matches any type except nil

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes for every value except `nil`. Use it for interface fields that must be present but may
	hold anything.

	@function any
	@within t
	@param value any -- The value to check.
	@return boolean -- `true` unless `value` is `nil`.
	@return string? -- `"any expected, got nil"` on failure.
]=]
function t.any(value)
	if value ~= nil then
		return true
	else
		return false, "any expected, got nil"
	end
end

--Lua primitives

--[[**
	ensures Lua primitive boolean type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "boolean"`.

	@function boolean
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value has the expected type.
	@return string? -- `"<type> expected, got <actual>"` on failure.
]=]
t.boolean = t.typeof("boolean")

--[[**
	ensures Lua primitive buffer type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when the value is a Luau `buffer`.

	@function buffer
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value has the expected type.
	@return string? -- `"<type> expected, got <actual>"` on failure.
]=]
t.buffer = t.typeof("buffer")

--[[**
	ensures Lua primitive thread type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when the value is a coroutine (`thread`).

	@function thread
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value has the expected type.
	@return string? -- `"<type> expected, got <actual>"` on failure.
]=]
t.thread = t.typeof("thread")

--[[**
	ensures Lua primitive callback type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when the value is a function. Also available as `t["function"]`. Every check constructor in `t` uses this internally to assert that the checks it receives are functions.

	@function callback
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value has the expected type.
	@return string? -- `"<type> expected, got <actual>"` on failure.
]=]
t.callback = t.typeof("function")
t["function"] = t.callback

--[[**
	ensures Lua primitive none type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes only for `nil`. Also available as `t["nil"]`. Useful inside [t.union] or [t.tuple] when a position must be empty.

	@function none
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value has the expected type.
	@return string? -- `"<type> expected, got <actual>"` on failure.
]=]
t.none = t.typeof("nil")
t["nil"] = t.none

--[[**
	ensures Lua primitive string type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when the value is a string.

	@function string
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value has the expected type.
	@return string? -- `"<type> expected, got <actual>"` on failure.
]=]
t.string = t.typeof("string")

--[[**
	ensures Lua primitive table type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when the value is a table (any table, including arrays and objects with metatables). Use [t.array], [t.map], [t.set] or [t.interface] to check the contents as well.

	@function table
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value has the expected type.
	@return string? -- `"<type> expected, got <actual>"` on failure.
]=]
t.table = t.typeof("table")

--[[**
	ensures Lua primitive userdata type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when Lua's `type(value)` is `"userdata"`, which is true for almost every Roblox data type (`CFrame`, `Instance`, `Color3`, ...) but not for `Vector3`, which is a native `vector`.

	@function userdata
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value has the expected type.
	@return string? -- `"<type> expected, got <actual>"` on failure.
]=]
t.userdata = t.type("userdata")

--[[**
	ensures Lua primitive vector type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when Lua's `type(value)` is `"vector"`, i.e. the value is a `Vector3` (Luau stores `Vector3` as a native vector). Equivalent in practice to `t.Vector3`.

	@function vector
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value has the expected type.
	@return string? -- `"<type> expected, got <actual>"` on failure.
]=]
t.vector = t.type("vector")

--[[**
	ensures value is a number and non-NaN

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when the value is a number **and is not NaN**. Every numeric check in `t`
	([t.integer], [t.numberMin], [t.numberConstrained], ...) is built on this, so NaN never
	slips through them either. Use [t.nan] if you specifically want to accept NaN.

	```lua
	print(t.number(1.5))  --> true
	print(t.number(0/0))  --> false, "unexpected NaN value"
	print(t.number("1"))  --> false, "number expected, got string"
	```

	@function number
	@within t
	@param value any -- The value to check.
	@return boolean -- `true` for any non-NaN number.
	@return string? -- `"number expected, got <type>"` or `"unexpected NaN value"` on failure.
]=]
function t.number(value)
	local valueType = typeof(value)
	if valueType == "number" then
		if value == value then
			return true
		else
			return false, "unexpected NaN value"
		end
	else
		return false, string.format("number expected, got %s", valueType)
	end
end

--[[**
	ensures value is NaN

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes only when the value is a number that is NaN (`value ~= value`). Non-numbers fail with
	a type message; ordinary numbers fail with `"unexpected non-NaN value"`.

	@function nan
	@within t
	@param value any -- The value to check.
	@return boolean -- `true` only for NaN.
	@return string? -- The failure message.
]=]
function t.nan(value)
	local valueType = typeof(value)
	if valueType == "number" then
		if value ~= value then
			return true
		else
			return false, "unexpected non-NaN value"
		end
	else
		return false, string.format("number expected, got %s", valueType)
	end
end

-- roblox types

--[[**
	ensures Roblox Axes type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Axes"`.

	@function Axes
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Axes`.
	@return string? -- `"Axes expected, got <actual>"` on failure.
]=]
t.Axes = t.typeof("Axes")

--[[**
	ensures Roblox BrickColor type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "BrickColor"`.

	@function BrickColor
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `BrickColor`.
	@return string? -- `"BrickColor expected, got <actual>"` on failure.
]=]
t.BrickColor = t.typeof("BrickColor")

--[[**
	ensures Roblox CatalogSearchParams type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "CatalogSearchParams"`.

	@function CatalogSearchParams
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `CatalogSearchParams`.
	@return string? -- `"CatalogSearchParams expected, got <actual>"` on failure.
]=]
t.CatalogSearchParams = t.typeof("CatalogSearchParams")

--[[**
	ensures Roblox CFrame type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "CFrame"`.

	@function CFrame
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `CFrame`.
	@return string? -- `"CFrame expected, got <actual>"` on failure.
]=]
t.CFrame = t.typeof("CFrame")

--[[**
	ensures Roblox Content type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Content"` (the `Content` data type used by asset properties).

	@function Content
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Content`.
	@return string? -- `"Content expected, got <actual>"` on failure.
]=]
t.Content = t.typeof("Content")

--[[**
	ensures Roblox Color3 type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Color3"`.

	@function Color3
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Color3`.
	@return string? -- `"Color3 expected, got <actual>"` on failure.
]=]
t.Color3 = t.typeof("Color3")

--[[**
	ensures Roblox ColorSequence type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "ColorSequence"`.

	@function ColorSequence
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `ColorSequence`.
	@return string? -- `"ColorSequence expected, got <actual>"` on failure.
]=]
t.ColorSequence = t.typeof("ColorSequence")

--[[**
	ensures Roblox ColorSequenceKeypoint type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "ColorSequenceKeypoint"`.

	@function ColorSequenceKeypoint
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `ColorSequenceKeypoint`.
	@return string? -- `"ColorSequenceKeypoint expected, got <actual>"` on failure.
]=]
t.ColorSequenceKeypoint = t.typeof("ColorSequenceKeypoint")

--[[**
	ensures Roblox DateTime type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "DateTime"`.

	@function DateTime
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `DateTime`.
	@return string? -- `"DateTime expected, got <actual>"` on failure.
]=]
t.DateTime = t.typeof("DateTime")

--[[**
	ensures Roblox DockWidgetPluginGuiInfo type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "DockWidgetPluginGuiInfo"`.

	@function DockWidgetPluginGuiInfo
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `DockWidgetPluginGuiInfo`.
	@return string? -- `"DockWidgetPluginGuiInfo expected, got <actual>"` on failure.
]=]
t.DockWidgetPluginGuiInfo = t.typeof("DockWidgetPluginGuiInfo")

--[[**
	ensures Roblox Enum type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Enum"` (the enum *type*, e.g. `Enum.Material`, not one of its items; see [t.EnumItem] and [t.enum]).

	@function Enum
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Enum`.
	@return string? -- `"Enum expected, got <actual>"` on failure.
]=]
t.Enum = t.typeof("Enum")

--[[**
	ensures Roblox EnumItem type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "EnumItem"` (an item such as `Enum.Material.Plastic`; use [t.enum] to also require a specific enum).

	@function EnumItem
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `EnumItem`.
	@return string? -- `"EnumItem expected, got <actual>"` on failure.
]=]
t.EnumItem = t.typeof("EnumItem")

--[[**
	ensures Roblox Enums type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Enums"` (the global `Enum` table itself).

	@function Enums
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Enums`.
	@return string? -- `"Enums expected, got <actual>"` on failure.
]=]
t.Enums = t.typeof("Enums")

--[[**
	ensures Roblox Faces type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Faces"`.

	@function Faces
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Faces`.
	@return string? -- `"Faces expected, got <actual>"` on failure.
]=]
t.Faces = t.typeof("Faces")

--[[**
	ensures Roblox FloatCurveKey type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "FloatCurveKey"`.

	@function FloatCurveKey
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `FloatCurveKey`.
	@return string? -- `"FloatCurveKey expected, got <actual>"` on failure.
]=]
t.FloatCurveKey = t.typeof("FloatCurveKey")

--[[**
	ensures Roblox Font type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Font"`.

	@function Font
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Font`.
	@return string? -- `"Font expected, got <actual>"` on failure.
]=]
t.Font = t.typeof("Font")

--[[**
	ensures Roblox Instance type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Instance"` (any `Instance`; use [t.instanceOf], [t.instanceIsA] or [t.children] to be more specific).

	@function Instance
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Instance`.
	@return string? -- `"Instance expected, got <actual>"` on failure.
]=]
t.Instance = t.typeof("Instance")

--[[**
	ensures Roblox NumberRange type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "NumberRange"`.

	@function NumberRange
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `NumberRange`.
	@return string? -- `"NumberRange expected, got <actual>"` on failure.
]=]
t.NumberRange = t.typeof("NumberRange")

--[[**
	ensures Roblox NumberSequence type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "NumberSequence"`.

	@function NumberSequence
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `NumberSequence`.
	@return string? -- `"NumberSequence expected, got <actual>"` on failure.
]=]
t.NumberSequence = t.typeof("NumberSequence")

--[[**
	ensures Roblox NumberSequenceKeypoint type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "NumberSequenceKeypoint"`.

	@function NumberSequenceKeypoint
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `NumberSequenceKeypoint`.
	@return string? -- `"NumberSequenceKeypoint expected, got <actual>"` on failure.
]=]
t.NumberSequenceKeypoint = t.typeof("NumberSequenceKeypoint")

--[[**
	ensures Roblox OverlapParams type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "OverlapParams"`.

	@function OverlapParams
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `OverlapParams`.
	@return string? -- `"OverlapParams expected, got <actual>"` on failure.
]=]
t.OverlapParams = t.typeof("OverlapParams")

--[[**
	ensures Roblox PathWaypoint type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "PathWaypoint"`.

	@function PathWaypoint
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `PathWaypoint`.
	@return string? -- `"PathWaypoint expected, got <actual>"` on failure.
]=]
t.PathWaypoint = t.typeof("PathWaypoint")

--[[**
	ensures Roblox PhysicalProperties type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "PhysicalProperties"`.

	@function PhysicalProperties
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `PhysicalProperties`.
	@return string? -- `"PhysicalProperties expected, got <actual>"` on failure.
]=]
t.PhysicalProperties = t.typeof("PhysicalProperties")

--[[**
	ensures Roblox Random type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Random"` (a `Random` object from `Random.new`).

	@function Random
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Random`.
	@return string? -- `"Random expected, got <actual>"` on failure.
]=]
t.Random = t.typeof("Random")

--[[**
	ensures Roblox Ray type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Ray"`.

	@function Ray
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Ray`.
	@return string? -- `"Ray expected, got <actual>"` on failure.
]=]
t.Ray = t.typeof("Ray")

--[[**
	ensures Roblox RaycastParams type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "RaycastParams"`.

	@function RaycastParams
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `RaycastParams`.
	@return string? -- `"RaycastParams expected, got <actual>"` on failure.
]=]
t.RaycastParams = t.typeof("RaycastParams")

--[[**
	ensures Roblox RaycastResult type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "RaycastResult"`.

	@function RaycastResult
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `RaycastResult`.
	@return string? -- `"RaycastResult expected, got <actual>"` on failure.
]=]
t.RaycastResult = t.typeof("RaycastResult")

--[[**
	ensures Roblox RBXScriptConnection type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "RBXScriptConnection"`.

	@function RBXScriptConnection
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `RBXScriptConnection`.
	@return string? -- `"RBXScriptConnection expected, got <actual>"` on failure.
]=]
t.RBXScriptConnection = t.typeof("RBXScriptConnection")

--[[**
	ensures Roblox RBXScriptSignal type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "RBXScriptSignal"`.

	@function RBXScriptSignal
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `RBXScriptSignal`.
	@return string? -- `"RBXScriptSignal expected, got <actual>"` on failure.
]=]
t.RBXScriptSignal = t.typeof("RBXScriptSignal")

--[[**
	ensures Roblox Rect type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Rect"`.

	@function Rect
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Rect`.
	@return string? -- `"Rect expected, got <actual>"` on failure.
]=]
t.Rect = t.typeof("Rect")

--[[**
	ensures Roblox Region3 type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Region3"`.

	@function Region3
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Region3`.
	@return string? -- `"Region3 expected, got <actual>"` on failure.
]=]
t.Region3 = t.typeof("Region3")

--[[**
	ensures Roblox Region3int16 type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Region3int16"`.

	@function Region3int16
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Region3int16`.
	@return string? -- `"Region3int16 expected, got <actual>"` on failure.
]=]
t.Region3int16 = t.typeof("Region3int16")

--[[**
	ensures Roblox TweenInfo type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "TweenInfo"`.

	@function TweenInfo
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `TweenInfo`.
	@return string? -- `"TweenInfo expected, got <actual>"` on failure.
]=]
t.TweenInfo = t.typeof("TweenInfo")

--[[**
	ensures Roblox UDim type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "UDim"`.

	@function UDim
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `UDim`.
	@return string? -- `"UDim expected, got <actual>"` on failure.
]=]
t.UDim = t.typeof("UDim")

--[[**
	ensures Roblox UDim2 type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "UDim2"`.

	@function UDim2
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `UDim2`.
	@return string? -- `"UDim2 expected, got <actual>"` on failure.
]=]
t.UDim2 = t.typeof("UDim2")

--[[**
	ensures Roblox Vector2 type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Vector2"`.

	@function Vector2
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Vector2`.
	@return string? -- `"Vector2 expected, got <actual>"` on failure.
]=]
t.Vector2 = t.typeof("Vector2")

--[[**
	ensures Roblox Vector2int16 type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Vector2int16"`.

	@function Vector2int16
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Vector2int16`.
	@return string? -- `"Vector2int16 expected, got <actual>"` on failure.
]=]
t.Vector2int16 = t.typeof("Vector2int16")

--[[**
	ensures Roblox Vector3 type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Vector3"` (the same as `t.vector`).

	@function Vector3
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Vector3`.
	@return string? -- `"Vector3 expected, got <actual>"` on failure.
]=]
t.Vector3 = t.typeof("Vector3")

--[[**
	ensures Roblox Vector3int16 type

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when `typeof(value) == "Vector3int16"`.

	@function Vector3int16
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a `Vector3int16`.
	@return string? -- `"Vector3int16 expected, got <actual>"` on failure.
]=]
t.Vector3int16 = t.typeof("Vector3int16")

--[[**
	ensures value is any of the given literal values

	@param literals The literals to check against

	@returns A function that will return true if the condition is passed
**--]]
--[=[
	Returns a check that passes when the value is equal (`==`) to any entry of the `literals`
	array. Same as [t.literal] with several arguments, but takes a table, which is convenient
	when the allowed values already live in a list. The failure message is the generic
	`"bad type for literal list"`.

	```lua
	local isDirection = t.literalList({ "North", "East", "South", "West" })
	```

	@function literalList
	@within t
	@param literals { any } -- The allowed values.
	@return Check -- Passes when the value equals one of the literals.
]=]
function t.literalList(literals)
	-- optimization for primitive types
	local set = {}
	for _, literal in ipairs(literals) do
		set[literal] = true
	end
	return function(value)
		if set[value] then
			return true
		end
		for _, literal in ipairs(literals) do
			if literal == value then
				return true
			end
		end

		return false, "bad type for literal list"
	end
end

--[[**
	ensures value is a given literal value

	@param literal The literal to use

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check for one or more exact values. With a single argument the check passes only
	when `value == literal` and fails with `"expected <literal>, got <value>"`. With several
	arguments it returns a [t.unionList] of one-literal checks (so the message becomes
	`"bad type for union"`). Deprecated alias: `t.exactly`.

	```lua
	local isTrue = t.literal(true)
	local isTeam = t.literal("Red", "Blue")
	print(isTeam("Green")) --> false, "bad type for union"
	```

	@function literal
	@within t
	@param ... any -- One or more values the checked value may equal.
	@return Check -- Passes when the value equals one of the literals.
]=]
function t.literal(...)
	local size = select("#", ...)
	if size == 1 then
		local literal = ...
		return function(value)
			if value ~= literal then
				return false, string.format("expected %s, got %s", tostring(literal), tostring(value))
			end

			return true
		end
	else
		local literals = {}
		for i = 1, size do
			local value = select(i, ...)
			literals[i] = t.literal(value)
		end

		return t.unionList(literals)
	end
end

--[[**
	DEPRECATED
	Please use t.literal
**--]]
--[=[
	Old name for [t.literal]; behaves identically.

	@function exactly
	@within t
	@deprecated v1.0.0 -- Use [t.literal] instead.
	@param ... any -- One or more values the checked value may equal.
	@return Check -- Passes when the value equals one of the literals.
]=]
t.exactly = t.literal

--[[**
	Returns a t.union of each key in the table as a t.literal

	@param keyTable The table to get keys from

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Returns a check that passes when the value is one of the **keys** of `keyTable`, built as
	`t.literal(key1, key2, ...)`. Handy for validating an option name against a dictionary of
	handlers. The key set is captured when `keyOf` is called; later changes to the table are not
	seen.

	```lua
	local handlers = { Jump = jump, Crouch = crouch }
	local isAction = t.keyOf(handlers)
	print(isAction("Jump"))  --> true
	print(isAction("Fly"))   --> false
	```

	@function keyOf
	@within t
	@param keyTable { [any]: any } -- The table whose keys are the allowed values.
	@return Check -- Passes when the value equals one of the keys.
]=]
function t.keyOf(keyTable)
	local keys = {}
	local length = 0
	for key in pairs(keyTable) do
		length = length + 1
		keys[length] = key
	end

	return t.literal(table.unpack(keys, 1, length))
end

--[[**
	Returns a t.union of each value in the table as a t.literal

	@param valueTable The table to get values from

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Returns a check that passes when the value is one of the **values** of `valueTable`, built as
	`t.literal(value1, value2, ...)`. Useful with enum-like tables of constants. The value set is
	captured when `valueOf` is called.

	```lua
	local Rarity = { Common = 1, Rare = 2, Epic = 3 }
	local isRarity = t.valueOf(Rarity)
	print(isRarity(2)) --> true
	```

	@function valueOf
	@within t
	@param valueTable { [any]: any } -- The table whose values are the allowed values.
	@return Check -- Passes when the value equals one of the table's values.
]=]
function t.valueOf(valueTable)
	local values = {}
	local length = 0
	for _, value in pairs(valueTable) do
		length = length + 1
		values[length] = value
	end

	return t.literal(table.unpack(values, 1, length))
end

--[[**
	ensures value is an integer

	@param value The value to check against

	@returns True iff the condition is satisfied, false otherwise
**--]]
--[=[
	Passes when the value is a non-NaN number with no fractional part (`value % 1 == 0`).
	`math.huge` passes; `1.5` fails with `"integer expected, got 1.5"`.

	@function integer
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is an integer.
	@return string? -- The failure message.
]=]
function t.integer(value)
	local success, errMsg = t.number(value)
	if not success then
		return false, errMsg or ""
	end

	if value % 1 == 0 then
		return true
	else
		return false, string.format("integer expected, got %s", value)
	end
end

--[[**
	ensures value is a number where min <= value

	@param min The minimum to use

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes for numbers where `value >= min` (inclusive). Non-numbers and NaN
	fail with the [t.number] message.

	```lua
	local isNonNegative = t.numberMin(0)
	```

	@function numberMin
	@within t
	@param min number -- The smallest accepted value.
	@return Check -- Fails with `"number >= <min> expected, got <value>"`.
]=]
function t.numberMin(min)
	return function(value)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg or ""
		end

		if value >= min then
			return true
		else
			return false, string.format("number >= %s expected, got %s", min, value)
		end
	end
end

--[[**
	ensures value is a number where value <= max

	@param max The maximum to use

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes for numbers where `value <= max` (inclusive).

	@function numberMax
	@within t
	@param max number -- The largest accepted value.
	@return Check -- Fails with `"number <= <max> expected, got <value>"`.
]=]
function t.numberMax(max)
	return function(value)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg
		end

		if value <= max then
			return true
		else
			return false, string.format("number <= %s expected, got %s", max, value)
		end
	end
end

--[[**
	ensures value is a number where min < value

	@param min The minimum to use

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes for numbers where `value > min` (exclusive).

	@function numberMinExclusive
	@within t
	@param min number -- The bound; the value itself is not accepted.
	@return Check -- Fails with `"number > <min> expected, got <value>"`.
]=]
function t.numberMinExclusive(min)
	return function(value)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg or ""
		end

		if min < value then
			return true
		else
			return false, string.format("number > %s expected, got %s", min, value)
		end
	end
end

--[[**
	ensures value is a number where value < max

	@param max The maximum to use

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes for numbers where `value < max` (exclusive).

	@function numberMaxExclusive
	@within t
	@param max number -- The bound; the value itself is not accepted.
	@return Check -- Fails with `"number < <max> expected, got <value>"`.
]=]
function t.numberMaxExclusive(max)
	return function(value)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg or ""
		end

		if value < max then
			return true
		else
			return false, string.format("number < %s expected, got %s", max, value)
		end
	end
end

--[[**
	ensures value is a number where value > 0

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Passes for numbers strictly greater than zero; equivalent to `t.numberMinExclusive(0)`. Zero
	fails. This is a ready-made check, not a constructor: call it with the value directly.

	@function numberPositive
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a number `> 0`.
	@return string? -- The failure message.
]=]
t.numberPositive = t.numberMinExclusive(0)

--[[**
	ensures value is a number where value < 0

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Passes for numbers strictly less than zero; equivalent to `t.numberMaxExclusive(0)`. Zero
	fails. This is a ready-made check, not a constructor: call it with the value directly.

	@function numberNegative
	@within t
	@param value any -- The value to check.
	@return boolean -- Whether the value is a number `< 0`.
	@return string? -- The failure message.
]=]
t.numberNegative = t.numberMaxExclusive(0)

--[[**
	ensures value is a number where min <= value <= max

	@param min The minimum to use
	@param max The maximum to use

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes for numbers where `min <= value <= max` (both inclusive).

	```lua
	local isPercent = t.numberConstrained(0, 100)
	```

	@function numberConstrained
	@within t
	@param min number -- The smallest accepted value.
	@param max number -- The largest accepted value.
	@return Check -- Fails with the [t.numberMin] or [t.numberMax] message.
	@error string -- If `min` or `max` is not a number (asserted when the check is built).
]=]
function t.numberConstrained(min, max)
	assert(t.number(min))
	assert(t.number(max))
	local minCheck = t.numberMin(min)
	local maxCheck = t.numberMax(max)

	return function(value)
		local minSuccess, minErrMsg = minCheck(value)
		if not minSuccess then
			return false, minErrMsg or ""
		end

		local maxSuccess, maxErrMsg = maxCheck(value)
		if not maxSuccess then
			return false, maxErrMsg or ""
		end

		return true
	end
end

--[[**
	ensures value is a number where min < value < max

	@param min The minimum to use
	@param max The maximum to use

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes for numbers where `min < value < max` (both exclusive).

	@function numberConstrainedExclusive
	@within t
	@param min number -- The lower bound, not accepted itself.
	@param max number -- The upper bound, not accepted itself.
	@return Check -- Fails with the [t.numberMinExclusive] or [t.numberMaxExclusive] message.
	@error string -- If `min` or `max` is not a number (asserted when the check is built).
]=]
function t.numberConstrainedExclusive(min, max)
	assert(t.number(min))
	assert(t.number(max))
	local minCheck = t.numberMinExclusive(min)
	local maxCheck = t.numberMaxExclusive(max)

	return function(value)
		local minSuccess, minErrMsg = minCheck(value)
		if not minSuccess then
			return false, minErrMsg or ""
		end

		local maxSuccess, maxErrMsg = maxCheck(value)
		if not maxSuccess then
			return false, maxErrMsg or ""
		end

		return true
	end
end

--[[**
	ensures value matches string pattern

	@param string pattern to check against

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes for strings matching a Lua string pattern (`string.match`).
	Non-strings fail with the [t.string] message. Anchor the pattern (`^...$`) if the whole
	string must match.

	```lua
	local isHexColor = t.match("^#%x%x%x%x%x%x$")
	print(isHexColor("#ff8800")) --> true
	```

	@function match
	@within t
	@param pattern string -- A Lua pattern.
	@return Check -- Fails with `"<value> failed to match pattern <pattern>"`.
	@error string -- If `pattern` is not a string (asserted when the check is built).
]=]
function t.match(pattern)
	assert(t.string(pattern))
	return function(value)
		local stringSuccess, stringErrMsg = t.string(value)
		if not stringSuccess then
			return false, stringErrMsg
		end

		if string.match(value, pattern) == nil then
			return false, string.format("%q failed to match pattern %q", value, pattern)
		end

		return true
	end
end

--[[**
	ensures value is either nil or passes check

	@param check The check to use

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes when the value is `nil` **or** passes `check`. This is how you
	mark interface fields and tuple positions as optional. Failure messages are prefixed with
	`"(optional) "`.

	```lua
	local IsConfig = t.interface({
		Name = t.string,
		Speed = t.optional(t.number), -- may be omitted
	})
	```

	@function optional
	@within t
	@param check Check -- The check to apply when the value is not `nil`.
	@return Check -- Passes for `nil` or any value accepted by `check`.
	@error string -- If `check` is not a function (asserted when the check is built).
]=]
function t.optional(check)
	assert(t.callback(check))
	return function(value)
		if value == nil then
			return true
		end

		local success, errMsg = check(value)
		if success then
			return true
		else
			return false, string.format("(optional) %s", errMsg or "")
		end
	end
end

--[[**
	matches given tuple against tuple type definition

	@param ... The type definition for the tuples

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check for an **argument list** rather than a single value. The returned function
	takes any number of arguments and checks the i-th argument against the i-th check. Extra
	arguments beyond the checks are ignored; missing arguments are checked as `nil`, so wrap a
	check in [t.optional] to allow it to be absent. Failures report the index:
	`"Bad tuple index #2:\n\t<message>"`.

	```lua
	local checkArgs = t.tuple(t.instanceIsA("Player"), t.string, t.optional(t.number))

	local function giveItem(player, itemName, amount)
		assert(checkArgs(player, itemName, amount))
	end
	```

	@function tuple
	@within t
	@param ... Check -- One check per positional argument.
	@return (...any) -> (boolean, string?) -- A check that takes the arguments as varargs.
]=]
function t.tuple(...)
	local checks = { ... }
	return function(...)
		local args = { ... }
		for i, check in ipairs(checks) do
			local success, errMsg = check(args[i])
			if success == false then
				return false, string.format("Bad tuple index #%s:\n\t%s", i, errMsg or "")
			end
		end

		return true
	end
end

--[[**
	ensures all keys in given table pass check

	@param check The function to use to check the keys

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes when the value is a table and **every key** passes `check`.
	Values are not inspected. Failures read `"bad key <key>:\n\t<message>"`.

	@function keys
	@within t
	@param check Check -- Applied to each key.
	@return Check -- Passes for tables whose keys all satisfy `check` (including empty tables).
	@error string -- If `check` is not a function (asserted when the check is built).
]=]
function t.keys(check)
	assert(t.callback(check))
	return function(value)
		local tableSuccess, tableErrMsg = t.table(value)
		if tableSuccess == false then
			return false, tableErrMsg or ""
		end

		for key in pairs(value) do
			local success, errMsg = check(key)
			if success == false then
				return false, string.format("bad key %s:\n\t%s", tostring(key), errMsg or "")
			end
		end

		return true
	end
end

--[[**
	ensures all values in given table pass check

	@param check The function to use to check the values

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes when the value is a table and **every value** passes `check`.
	Keys are not inspected. Failures read `"bad value for key <key>:\n\t<message>"`.

	@function values
	@within t
	@param check Check -- Applied to each value.
	@return Check -- Passes for tables whose values all satisfy `check` (including empty tables).
	@error string -- If `check` is not a function (asserted when the check is built).
]=]
function t.values(check)
	assert(t.callback(check))
	return function(value)
		local tableSuccess, tableErrMsg = t.table(value)
		if tableSuccess == false then
			return false, tableErrMsg or ""
		end

		for key, val in pairs(value) do
			local success, errMsg = check(val)
			if success == false then
				return false, string.format("bad value for key %s:\n\t%s", tostring(key), errMsg or "")
			end
		end

		return true
	end
end

--[[**
	ensures value is a table and all keys pass keyCheck and all values pass valueCheck

	@param keyCheck The function to use to check the keys
	@param valueCheck The function to use to check the values

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check for dictionaries: the value must be a table, every key must pass `keyCheck`
	and every value must pass `valueCheck`. Equivalent to [t.keys] followed by [t.values]. Empty
	tables pass.

	```lua
	local isScoreboard = t.map(t.instanceIsA("Player"), t.integer)
	```

	@function map
	@within t
	@param keyCheck Check -- Applied to each key.
	@param valueCheck Check -- Applied to each value.
	@return Check -- Passes for tables whose entries all satisfy both checks.
	@error string -- If either argument is not a function (asserted when the check is built).
]=]
function t.map(keyCheck, valueCheck)
	assert(t.callback(keyCheck))
	assert(t.callback(valueCheck))
	local keyChecker = t.keys(keyCheck)
	local valueChecker = t.values(valueCheck)

	return function(value)
		local keySuccess, keyErr = keyChecker(value)
		if not keySuccess then
			return false, keyErr or ""
		end

		local valueSuccess, valueErr = valueChecker(value)
		if not valueSuccess then
			return false, valueErr or ""
		end

		return true
	end
end

--[[**
	ensures value is a table and all keys pass valueCheck and all values are true

	@param valueCheck The function to use to check the values

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check for set-like tables of the form `{ [item] = true }`: every key must pass
	`valueCheck` and every value must be exactly `true`. Equivalent to
	`t.map(valueCheck, t.literal(true))`.

	```lua
	local isNameSet = t.set(t.string)
	print(isNameSet({ Alice = true, Bob = true })) --> true
	```

	@function set
	@within t
	@param valueCheck Check -- Applied to each key of the set.
	@return Check -- Passes for tables whose keys satisfy `valueCheck` and whose values are all `true`.
]=]
function t.set(valueCheck)
	return t.map(valueCheck, t.literal(true))
end

do
	local arrayKeysCheck = t.keys(t.integer)
--[[**
		ensures value is an array and all values of the array match check

		@param check The check to compare all values with

		@returns A function that will return true iff the condition is passed
	**--]]
	--[=[
		Returns a check for proper arrays: the value must be a table whose keys are exactly
		`1..n` with no gaps (sparse or mixed tables fail with `"[array] key <k> must be sequential"`)
		and whose every element passes `check`. Empty tables pass.

		```lua
		local isPath = t.array(t.Vector3)
		print(isPath({ Vector3.zero, Vector3.one })) --> true
		print(isPath({ [1] = Vector3.zero, [3] = Vector3.one })) --> false
		```

		@function array
		@within t
		@param check Check -- Applied to each element.
		@return Check -- Passes for sequential arrays whose elements all satisfy `check`.
		@error string -- If `check` is not a function (asserted when the check is built).
	]=]
	function t.array(check)
		assert(t.callback(check))
		local valuesCheck = t.values(check)

		return function(value)
			local keySuccess, keyErrMsg = arrayKeysCheck(value)
			if keySuccess == false then
				return false, string.format("[array] %s", keyErrMsg or "")
			end

			-- # is unreliable for sparse arrays
			-- Count upwards using ipairs to avoid false positives from the behavior of #
			local arraySize = 0

			for _ in ipairs(value) do
				arraySize = arraySize + 1
			end

			for key in pairs(value) do
				if key < 1 or key > arraySize then
					return false, string.format("[array] key %s must be sequential", tostring(key))
				end
			end

			local valueSuccess, valueErrMsg = valuesCheck(value)
			if not valueSuccess then
				return false, string.format("[array] %s", valueErrMsg or "")
			end

			return true
		end
	end

--[[**
		ensures value is an array of a strict makeup and size

		@param check The check to compare all values with

		@returns A function that will return true iff the condition is passed
	**--]]
	--[=[
		Returns a check for a fixed-length, positionally typed array (a tuple stored in a table).
		The value must be a sequential array with **at most** as many elements as there are checks,
		and element `i` must pass check `i`. Missing trailing elements are checked as `nil`, so use
		[t.optional] to allow them.

		```lua
		local isPair = t.strictArray(t.string, t.number)
		print(isPair({ "Coins", 10 }))        --> true
		print(isPair({ "Coins", 10, true }))  --> false, "[strictArray] Array size exceeds limit of 2"
		```

		@function strictArray
		@within t
		@param ... Check -- One check per array index.
		@return Check -- Passes for arrays that match the checks position by position.
		@error string -- If any argument is not a function (asserted when the check is built).
	]=]
	function t.strictArray(...)
		local valueTypes = { ... }
		assert(t.array(t.callback)(valueTypes))

		return function(value)
			local keySuccess, keyErrMsg = arrayKeysCheck(value)
			if keySuccess == false then
				return false, string.format("[strictArray] %s", keyErrMsg or "")
			end

			-- If there's more than the set array size, disallow
			if #valueTypes < #value then
				return false, string.format("[strictArray] Array size exceeds limit of %d", #valueTypes)
			end

			for idx, typeFn in pairs(valueTypes) do
				local typeSuccess, typeErrMsg = typeFn(value[idx])
				if not typeSuccess then
					return false, string.format("[strictArray] Array index #%d - %s", idx, typeErrMsg)
				end
			end

			return true
		end
	end
end

do
	local callbackArray = t.array(t.callback)
--[[**
		creates a union type

		@param checks The checks to union

		@returns A function that will return true iff the condition is passed
	**--]]
	--[=[
		Returns a check that passes when **any** check in the `checks` array passes (a union / "or").
		Checks are tried in order and the first success wins. The failure message is the generic
		`"bad type for union"`. [t.union] is the vararg form.

		@function unionList
		@within t
		@param checks { Check } -- The alternatives.
		@return Check -- Passes when at least one alternative passes.
		@error string -- If `checks` is not an array of functions (asserted when the check is built).
	]=]
	function t.unionList(checks)
		assert(callbackArray(checks))

		return function(value)
			for _, check in ipairs(checks) do
				if check(value) then
					return true
				end
			end

			return false, "bad type for union"
		end
	end

--[[**
		creates a union type

		@param ... The checks to union

		@returns A function that will return true iff the condition is passed
	**--]]
	--[=[
		Returns a check that passes when **any** of the given checks passes (a union / "or"). Alias:
		`t.some`. Same as `t.unionList({ ... })`.

		```lua
		local isIdentifier = t.union(t.string, t.number)
		local isPartOrModel = t.union(t.instanceIsA("BasePart"), t.instanceIsA("Model"))
		```

		@function union
		@within t
		@param ... Check -- The alternatives.
		@return Check -- Passes when at least one alternative passes; fails with `"bad type for union"`.
	]=]
	function t.union(...)
		return t.unionList({ ... })
	end

--[[**
		Alias for t.union
	**--]]
	--[=[
		Alias of [t.union].

		@function some
		@within t
		@param ... Check -- The alternatives.
		@return Check -- Passes when at least one alternative passes.
	]=]
	t.some = t.union

--[[**
		creates an intersection type

		@param checks The checks to intersect

		@returns A function that will return true iff the condition is passed
	**--]]
	--[=[
		Returns a check that passes only when **every** check in the `checks` array passes (an
		intersection / "and"). Checks run in order and the first failure's message is returned.
		[t.intersection] is the vararg form.

		@function intersectionList
		@within t
		@param checks { Check } -- The checks that must all pass.
		@return Check -- Passes when every check passes.
		@error string -- If `checks` is not an array of functions (asserted when the check is built).
	]=]
	function t.intersectionList(checks)
		assert(callbackArray(checks))

		return function(value)
			for _, check in ipairs(checks) do
				local success, errMsg = check(value)
				if not success then
					return false, errMsg or ""
				end
			end

			return true
		end
	end

--[[**
		creates an intersection type

		@param ... The checks to intersect

		@returns A function that will return true iff the condition is passed
	**--]]
	--[=[
		Returns a check that passes only when **every** given check passes (an intersection /
		"and"). Alias: `t.every`. Same as `t.intersectionList({ ... })`. Useful for adding a
		constraint to an existing check.

		```lua
		local isEvenInteger = t.intersection(t.integer, function(n)
			return n % 2 == 0, "even number expected"
		end)
		```

		@function intersection
		@within t
		@param ... Check -- The checks that must all pass.
		@return Check -- Passes when every check passes; fails with the first failing check's message.
	]=]
	function t.intersection(...)
		return t.intersectionList({ ... })
	end

--[[**
		Alias for t.intersection
	**--]]
	--[=[
		Alias of [t.intersection].

		@function every
		@within t
		@param ... Check -- The checks that must all pass.
		@return Check -- Passes when every check passes.
	]=]
	t.every = t.intersection
end

do
	local checkInterface = t.map(t.any, t.callback)
--[[**
		ensures value matches given interface definition

		@param checkTable The interface definition

		@returns A function that will return true iff the condition is passed
	**--]]
	--[=[
		Returns a check for objects (dictionaries with known field names). The value must be a table
		and, for each `key = check` pair in `checkTable`, `value[key]` must pass `check`. Fields not
		listed in `checkTable` are **allowed** and ignored; use [t.strictInterface] to forbid them.
		Wrap a field's check in [t.optional] to make the field optional. Failures read
		`"[interface] bad value for <key>:\n\t<message>"`.

		```lua
		local IsItem = t.interface({
			Id = t.string,
			Price = t.numberMin(0),
			Tags = t.optional(t.array(t.string)),
		})

		print(IsItem({ Id = "sword", Price = 50, Extra = true })) --> true (Extra is ignored)
		```

		@function interface
		@within t
		@param checkTable { [any]: Check } -- Field name to check for that field.
		@return Check -- Passes for tables whose listed fields all satisfy their checks.
		@error string -- If `checkTable` is not a table of functions (asserted when the check is built).
	]=]
	function t.interface(checkTable)
		assert(checkInterface(checkTable))
		return function(value)
			local tableSuccess, tableErrMsg = t.table(value)
			if tableSuccess == false then
				return false, tableErrMsg or ""
			end

			for key, check in pairs(checkTable) do
				local success, errMsg = check(value[key])
				if success == false then
					return false, string.format("[interface] bad value for %s:\n\t%s", tostring(key), errMsg or "")
				end
			end

			return true
		end
	end

--[[**
		ensures value matches given interface definition strictly

		@param checkTable The interface definition

		@returns A function that will return true iff the condition is passed
	**--]]
	--[=[
		Like [t.interface], but additionally fails if the value contains **any key not present** in
		`checkTable`, with the message `"[interface] unexpected field <key>"`. Use it for data that
		crosses a trust boundary (remotes, saved data) where unknown fields should be rejected.

		```lua
		local IsMove = t.strictInterface({ X = t.number, Y = t.number })
		print(IsMove({ X = 1, Y = 2, Z = 3 })) --> false, '[interface] unexpected field "Z"'
		```

		@function strictInterface
		@within t
		@param checkTable { [any]: Check } -- Field name to check for that field.
		@return Check -- Passes for tables with exactly the listed fields, each satisfying its check.
		@error string -- If `checkTable` is not a table of functions (asserted when the check is built).
	]=]
	function t.strictInterface(checkTable)
		assert(checkInterface(checkTable))
		return function(value)
			local tableSuccess, tableErrMsg = t.table(value)
			if tableSuccess == false then
				return false, tableErrMsg or ""
			end

			for key, check in pairs(checkTable) do
				local success, errMsg = check(value[key])
				if success == false then
					return false, string.format("[interface] bad value for %s:\n\t%s", tostring(key), errMsg or "")
				end
			end

			for key in pairs(value) do
				if not checkTable[key] then
					return false, string.format("[interface] unexpected field %q", tostring(key))
				end
			end

			return true
		end
	end
end

--[[**
	ensure value is an Instance and it's ClassName matches the given ClassName

	@param className The class name to check for

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes when the value is an `Instance` whose `ClassName` is **exactly**
	`className` (no inheritance; a `MeshPart` is not a `"Part"`). Use [t.instanceIsA] for an
	`IsA` comparison. If `childTable` is given, the instance's children are also checked with
	[t.children]. Alias: `t.instance`.

	```lua
	local isCrate = t.instanceOf("Part", {
		Lid = t.instanceIsA("BasePart"),
		Prompt = t.optional(t.instanceOf("ProximityPrompt")),
	})
	```

	@function instanceOf
	@within t
	@param className string -- The exact `ClassName` required.
	@param childTable { [string]: Check }? -- Optional child-name to check table, as for [t.children].
	@return Check -- Fails with `"<className> expected, got <actual ClassName>"` or a [t.children] message.
	@error string -- If `className` is not a string (asserted when the check is built).
]=]
function t.instanceOf(className, childTable)
	assert(t.string(className))

	local childrenCheck
	if childTable ~= nil then
		childrenCheck = t.children(childTable)
	end

	return function(value)
		local instanceSuccess, instanceErrMsg = t.Instance(value)
		if not instanceSuccess then
			return false, instanceErrMsg or ""
		end

		if value.ClassName ~= className then
			return false, string.format("%s expected, got %s", className, value.ClassName)
		end

		if childrenCheck then
			local childrenSuccess, childrenErrMsg = childrenCheck(value)
			if not childrenSuccess then
				return false, childrenErrMsg
			end
		end

		return true
	end
end

--[=[
	Alias of [t.instanceOf].

	@function instance
	@within t
	@param className string -- The exact `ClassName` required.
	@param childTable { [string]: Check }? -- Optional child-name to check table.
	@return Check -- Passes for instances of exactly that class.
]=]
t.instance = t.instanceOf

--[[**
	ensure value is an Instance and it's ClassName matches the given ClassName by an IsA comparison

	@param className The class name to check for

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes when the value is an `Instance` for which `value:IsA(className)`
	is true, so subclasses are accepted (`"BasePart"` matches `Part`, `MeshPart`, `WedgePart`...).
	This is usually what you want for instance arguments. If `childTable` is given, the
	instance's children are also checked with [t.children].

	```lua
	local checkArgs = t.tuple(t.instanceIsA("Player"), t.instanceIsA("Tool"))
	```

	@function instanceIsA
	@within t
	@param className string -- The class (or superclass) name passed to `IsA`.
	@param childTable { [string]: Check }? -- Optional child-name to check table, as for [t.children].
	@return Check -- Fails with `"<className> expected, got <actual ClassName>"` or a [t.children] message.
	@error string -- If `className` is not a string (asserted when the check is built).
]=]
function t.instanceIsA(className, childTable)
	assert(t.string(className))

	local childrenCheck
	if childTable ~= nil then
		childrenCheck = t.children(childTable)
	end

	return function(value)
		local instanceSuccess, instanceErrMsg = t.Instance(value)
		if not instanceSuccess then
			return false, instanceErrMsg or ""
		end

		if not value:IsA(className) then
			return false, string.format("%s expected, got %s", className, value.ClassName)
		end

		if childrenCheck then
			local childrenSuccess, childrenErrMsg = childrenCheck(value)
			if not childrenSuccess then
				return false, childrenErrMsg
			end
		end

		return true
	end
end

--[[**
	ensures value is an enum of the correct type

	@param enum The enum to check

	@returns A function that will return true iff the condition is passed
**--]]
--[=[
	Returns a check that passes when the value is an `EnumItem` belonging to the given enum
	(`value.EnumType == enum`). Items of other enums fail with
	`"enum of <enum> expected, got enum of <other>"`; non-EnumItems fail with the [t.EnumItem]
	message.

	```lua
	local isMaterial = t.enum(Enum.Material)
	print(isMaterial(Enum.Material.Wood))   --> true
	print(isMaterial(Enum.KeyCode.A))       --> false
	```

	@function enum
	@within t
	@param enum Enum -- The enum type, e.g. `Enum.Material`.
	@return Check -- Passes for items of that enum.
	@error string -- If `enum` is not an `Enum` (asserted when the check is built).
]=]
function t.enum(enum)
	assert(t.Enum(enum))
	return function(value)
		local enumItemSuccess, enumItemErrMsg = t.EnumItem(value)
		if not enumItemSuccess then
			return false, enumItemErrMsg
		end

		if value.EnumType == enum then
			return true
		else
			return false, string.format("enum of %s expected, got enum of %s", tostring(enum), tostring(value.EnumType))
		end
	end
end

do
	local checkWrap = t.tuple(t.callback, t.callback)

--[[**
		wraps a callback in an assert with checkArgs

		@param callback The function to wrap
		@param checkArgs The function to use to check arguments in the assert

		@returns A function that first asserts using checkArgs and then calls callback
	**--]]
	--[=[
		Returns a new function that first runs `assert(checkArgs(...))` on its arguments and then
		calls `callback(...)`, returning whatever `callback` returns. `checkArgs` is normally a
		[t.tuple]. This is a convenient way to publish a guarded version of a function without
		editing its body.

		```lua
		local function setHealth(humanoid, health)
			humanoid.Health = health
		end

		setHealth = t.wrap(setHealth, t.tuple(t.instanceIsA("Humanoid"), t.numberMin(0)))
		setHealth(workspace.Dummy.Humanoid, -5) -- errors: "Bad tuple index #2: ..."
		```

		@function wrap
		@within t
		@param callback (A...) -> R... -- The function to guard.
		@param checkArgs (A...) -> (boolean, string?) -- A check for the whole argument list, usually from [t.tuple].
		@return (A...) -> R... -- A function that asserts the arguments and then calls `callback`.
		@error string -- If either argument is not a function (asserted when `wrap` is called), or, from the returned function, the message of a failed check.
	]=]
	function t.wrap(callback, checkArgs)
		assert(checkWrap(callback, checkArgs))
		return function(...)
			assert(checkArgs(...))
			return callback(...)
		end
	end
end

--[[**
	asserts a given check

	@param check The function to wrap with an assert

	@returns A function that simply wraps the given check in an assert
**--]]
--[=[
	Turns a check into an **assertion**: the returned function calls `assert(check(...))`, so it
	errors with the check's message on failure and returns nothing on success. Use it at the top
	of functions or when validating data where a boolean result is not useful.

	```lua
	local assertConfig = t.strict(t.interface({ Speed = t.number }))
	assertConfig({ Speed = "fast" }) -- error: [interface] bad value for Speed: number expected, got string
	```

	@function strict
	@within t
	@param check (...any) -> (boolean, string?) -- Any check, including a [t.tuple] check.
	@return (...any) -> () -- A function that raises the check's message if the check fails.
	@error string -- From the returned function, the message of the failed check.
]=]
function t.strict(check)
	return function(...)
		assert(check(...))
	end
end

do
	local checkChildren = t.map(t.string, t.callback)

--[[**
		Takes a table where keys are child names and values are functions to check the children against.
		Pass an instance tree into the function.
		If at least one child passes each check, the overall check passes.

		Warning! If you pass in a tree with more than one child of the same name, this function will always return false

		@param checkTable The table to check against

		@returns A function that checks an instance tree
	**--]]
	--[=[
		Returns a check for an instance's **child tree**. The value must be an `Instance`; for each
		`name = check` pair in `checkTable`, the child called `name` (or `nil` if there is none) is
		passed to `check`. Wrap a check in [t.optional] to allow a child to be missing, and use
		[t.instanceOf] / [t.instanceIsA] with their own `childTable` to nest deeper. Children whose
		names are not in `checkTable` are ignored.

		:::caution
		If the instance has two or more children sharing a name that appears in `checkTable`, the
		check fails with `"Cannot process multiple children with the same name"`, even if one of
		them would have passed.
		:::

		```lua
		local isCharacter = t.children({
			Humanoid = t.instanceOf("Humanoid"),
			HumanoidRootPart = t.instanceIsA("BasePart"),
			Head = t.instanceIsA("BasePart"),
		})
		print(isCharacter(player.Character))
		```

		@function children
		@within t
		@param checkTable { [string]: Check } -- Child name to the check for that child.
		@return Check -- Fails with `"[<FullName>.<child>] <message>"` when a child does not satisfy its check.
		@error string -- If `checkTable` is not a string-keyed table of functions (asserted when the check is built).
	]=]
	function t.children(checkTable)
		assert(checkChildren(checkTable))

		return function(value)
			local instanceSuccess, instanceErrMsg = t.Instance(value)
			if not instanceSuccess then
				return false, instanceErrMsg or ""
			end

			local childrenByName = {}
			for _, child in ipairs(value:GetChildren()) do
				local name = child.Name
				if checkTable[name] then
					if childrenByName[name] then
						return false, string.format("Cannot process multiple children with the same name %q", name)
					end

					childrenByName[name] = child
				end
			end

			for name, check in pairs(checkTable) do
				local success, errMsg = check(childrenByName[name])
				if not success then
					return false, string.format("[%s.%s] %s", value:GetFullName(), name, errMsg or "")
				end
			end

			return true
		end
	end
end

return t
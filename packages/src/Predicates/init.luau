--!strict
const RunService = game:GetService("RunService")
const Players = game:GetService("Players")

--Use Studio Wally Plugin to Install "kashtheking/t"
const T = require(script.Parent.T)

--[=[
	@class Predicates

	Ready-made predicate factories for [Binder](/api/Binder). A predicate is a function that
	receives a candidate instance and returns `true` or `false`, optionally followed by extra values.
	Binder forwards those extra values to your constructor, so a predicate both *filters* instances
	and *collects* the attribute, child, player or part you were going to look up anyway.

	The factories live in the `Predicates` sub-table of the module (and are also reachable as
	`Binder.Predicates.*`). Most accept an optional `warningName`: when it is given, a failing
	predicate prints a warning formatted with [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING)
	(or your own `warnFormatString`) telling you which instance failed and why. Without a
	`warningName` predicates fail silently.

	```lua
	local Binder = require(path.to.Binder)
	local Predicates = require(path.to.Predicates).Predicates

	-- Bind every Model tagged "Vendor" that has a numeric Price attribute and a
	-- ProximityPrompt child; the constructor receives them in that order.
	local vendors = Binder.new(function(model: Model, trove, price: number, prompt: ProximityPrompt)
		trove:Connect(prompt.Triggered, function(player)
			print(`{player.Name} paid {price}`)
		end)

		return trove
	end, {
		Tags = { "Vendor" },
		ClassNames = { "Model" },
		Predicate = Predicates.Combine {
			Predicates.Attribute("Price", "number", "VendorBinder"),
			Predicates.ChildWhichIsA("ProximityPrompt", "VendorBinder"),
		},
		AutoStart = true,
	})
	```

	The module table is `{ DEFAULT_WARN_FORMAT_STRING, doPredicateWarning, Predicates = { ... },
	T }`, where `T` is the bundled [t](/api/t) type-checking library for use as a
	[TypeValidator](#TypeValidator).

	**Credits:** type validation is done with [t](/api/t), originally by [Osyris](https://github.com/osyrisrblx). Wally installs it.

	Installation and guide: [Predicates package page](/docs/packages/predicates).
]=]

--[=[
	@type Predicate (any) -> (boolean, ...any)
	@within Predicates
	A function that receives the candidate (normally an `Instance`) and returns whether it passes,
	followed by any extra values. Binder passes those extra values to the constructor after the
	Trove. The first return value must be a real boolean.
]=]
export type Predicate = (any)->(boolean, ...any)

--[=[
	@prop DEFAULT_WARN_FORMAT_STRING string
	@within Predicates
	@readonly
	`"[%s] Predicate failed for %s: %s"`. The `string.format` pattern used for predicate warnings
	when no `warnFormatString` is supplied. The three `%s` receive the warning name, the instance's
	full name and the failure message, in that order; a custom format string must accept the same
	three arguments.
]=]
--Predicates to make life easier :)
const DEFAULT_WARN_FORMAT_STRING = "[%s] Predicate failed for %s: %s"

--[=[
	@type TypeValidator "any" | string | (value: any) -> any?
	@within Predicates
	Describes the type an attribute must have, for [Attribute](#Attribute) and
	[Attributes](#Attributes). Either a `typeof` name such as `"number"`, `"string"`, `"Color3"` or
	`"Vector3"`, the string `"any"` (accepts any non-nil value), or a function that receives the
	value and either errors, returns a message, or returns `true`.

	:::caution
	In the current version a function validator is always reported as failing, because the result
	check treats every return value (including `true`) as an error. Use a type-name string until
	this is fixed.
	:::
]=]
export type TypeValidator = ("any" | string | (value: any) -> any?)

--This should error if the type is invalid
local function assertType(value: any, typeValidator: TypeValidator)
	local t = typeof(value)
	if type(typeValidator) == "string" then
		if typeValidator == "any" and value ~= nil then
			return
		end

		if t ~= typeValidator then
			error(`Expected type \"{typeValidator}\" but got type \"{t}\"`)
		end
	else
		local result = typeValidator(value) --If this errors, the error message will be passed

		--Otherwise if it returned false (for bad type), give a generic error message
		if result ~= nil or result ~= true then
			error(`Invalid type \"{t}\"`, 1)
		end
	end
end

local function checkType(value: any, typeValidator: TypeValidator): string?
	local success, err = pcall(assertType, value, typeValidator)

	if not success then
		return (tostring(err) or "Invalid type")
	end

	return nil
end

--[=[
	Prints the standard predicate warning for `instance`. Does nothing when `warningName` is nil,
	which is how every factory in this module stays quiet unless you opt in. Useful when writing
	your own predicates so they warn in the same format as the built-in ones.

	```lua
	local function HasPrimaryPart(warningName: string?): Predicates.Predicate
		return function(model: Model)
			if not model.PrimaryPart then
				Predicates.doPredicateWarning(model, warningName, nil, "Missing PrimaryPart")
				return false
			end
			return true, model.PrimaryPart
		end
	end
	```

	@function doPredicateWarning
	@within Predicates
	@param instance Instance -- The instance that failed; its full name is included in the warning.
	@param warningName string? -- Label for the warning (typically the name of your binder or script). Nil suppresses the warning.
	@param warnFormatString string? -- `string.format` pattern with three `%s`; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@param warning string -- Why the predicate failed.
]=]
local function doPredicateWarning(instance: Instance, warningName: string?, warnFormatString: string?, warning: string)
	if not warningName then
		return --No warnings for no script name
	end
	
	local validWarningName = warningName :: string
	local validWarnFormatString = warnFormatString or DEFAULT_WARN_FORMAT_STRING
	local instancePath = instance:GetFullName()

	warn(
		validWarnFormatString:format(validWarningName, instancePath, warning)
	)
end

local function getPredicatePackedArgs(predicate: Predicate, instance: Instance): (boolean, {any}?)
	local result = {predicate(instance)}

	local success = result[1]

	if not success then
		return false, nil
	end

	return true, {unpack(result, 2)}
end

--[=[
	Runs several predicates in order and passes only if all of them pass. The extra values of every
	predicate are concatenated in the same order, so a constructor receives the values of the first
	predicate, then the second, and so on. The first failing predicate short-circuits the rest.

	```lua
	Predicate = Predicates.Combine {
		Predicates.Attribute("Speed", "number", "CarBinder"),
		Predicates.Child("Seat", "VehicleSeat", "CarBinder"),
	}
	-- constructor(instance, trove, speed: number, seat: VehicleSeat)
	```

	@function Combine
	@within Predicates
	@param predicates { Predicate } -- Predicates to run, in order.
	@return Predicate -- A predicate that passes when every input passes and returns all their extra values.
]=]
local Combine = function(predicates: {Predicate}): Predicate
	return function(instance: Instance): (boolean, any)
		local extraArgs: {any} = {}

		for _, predicate in predicates do
			local success, args = getPredicatePackedArgs(predicate, instance)

			if not success then
				return false, nil
			end

			for _, arg in args :: {any} do
				table.insert(extraArgs, arg)
			end
		end

		return true, unpack(extraArgs)
	end
end

--[=[
	Requires the instance to have the attribute `attribute` and returns its value as the extra
	value. When `typeValidator` is given the value must also satisfy it.

	:::caution
	The attribute is considered missing when its value is falsy, so a boolean attribute set to
	`false` fails this predicate. Use a different representation (for example a number or string)
	for flags that may be off.
	:::

	@function Attribute
	@within Predicates
	@param attribute string -- Name of the attribute to read.
	@param typeValidator TypeValidator? -- Type the value must have; skipped when nil.
	@param warningName string? -- Enables warnings on failure; see [doPredicateWarning](#doPredicateWarning).
	@param warnFormatString string? -- Custom warning format; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@return Predicate -- Passes with the attribute value as its extra value.
]=]
local Attribute = function(attribute: string, typeValidator: TypeValidator?, warningName: string?, warnFormatString: string?): Predicate
	return function(instance: Instance): (boolean, any)
		local value = instance:GetAttribute(attribute)

		if not value then
			doPredicateWarning(instance, warningName, warnFormatString, `Missing attribute \"{attribute}\"`)
			return false, nil
		end

		if typeValidator then
			local errorMessage = checkType(value, typeValidator)

			if errorMessage then
				doPredicateWarning(instance, warningName, warnFormatString, errorMessage)

				return false, nil
			end
		end

		return true, value
	end
end

--[=[
	Shorthand for [Combine](#Combine) over one [Attribute](#Attribute) predicate per entry of
	`attributes`. Every listed attribute must exist and match its validator; all of their values are
	returned as extra values.

	:::caution
	`attributes` is a dictionary, so the order in which the values are returned follows table
	iteration order and is not guaranteed. When you need more than one value in a known order, use
	[Combine](#Combine) with explicit [Attribute](#Attribute) calls instead.
	:::

	@function Attributes
	@within Predicates
	@param attributes { [string]: TypeValidator } -- Attribute names mapped to the type each must have (use `"any"` to accept anything).
	@param warningName string? -- Enables warnings on failure; see [doPredicateWarning](#doPredicateWarning).
	@param warnFormatString string? -- Custom warning format; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@return Predicate -- Passes with every attribute value as extra values.
]=]
local Attributes = function(attributes: {[string]: TypeValidator}, warningName: string?, warnFormatString: string?): Predicate
	local predicates: {Predicate} = {}

	for attributeName, attributeType in attributes do
		table.insert(
			predicates,
			Attribute(attributeName, attributeType, warningName, warnFormatString)
		)
	end

	return Combine(predicates)
end

--[=[
	Requires a direct child named `name` (found with `FindFirstChild`, so it does not wait) and
	returns it as the extra value. When `isA` is given the child must also satisfy `IsA(isA)`.

	@function Child
	@within Predicates
	@param name string -- Name of the child to find.
	@param isA string? -- Class name the child must be (or inherit from); skipped when nil.
	@param warningName string? -- Enables warnings on failure; see [doPredicateWarning](#doPredicateWarning).
	@param warnFormatString string? -- Custom warning format; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@return Predicate -- Passes with the child instance as its extra value.
]=]
local Child = function(name: string, isA: string?, warningName: string?, warnFormatString: string?): Predicate
	return function(instance: Instance): (boolean, Instance?)
		local child = instance:FindFirstChild(name)

		if not child then
			doPredicateWarning(instance, warningName, warnFormatString, `Failed to find child instance named \"{name}\"`)
			return false, nil
		end

		if isA and not child:IsA(isA) then
			doPredicateWarning(instance, warningName, warnFormatString, `Found child instance named \"{name}\" but it is not a \"{isA}\"`)
			return false, nil
		end

		return true, child
	end
end

--[=[
	Requires a direct child of class `isA` (via `FindFirstChildWhichIsA`, so subclasses count) and
	returns the first one found as the extra value.

	@function ChildWhichIsA
	@within Predicates
	@param isA string -- Class name the child must be or inherit from, e.g. `"BasePart"`.
	@param warningName string? -- Enables warnings on failure; see [doPredicateWarning](#doPredicateWarning).
	@param warnFormatString string? -- Custom warning format; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@return Predicate -- Passes with the matching child as its extra value.
]=]
local ChildWhichIsA = function(isA: string, warningName: string?, warnFormatString: string?): Predicate
	return function(instance: Instance): (boolean, Instance?)
		local child = instance:FindFirstChildWhichIsA(isA)

		if not child then
			doPredicateWarning(instance, warningName, warnFormatString, `No child of class \"{isA}\" found`)
			return false, nil
		end

		return true, child
	end
end

--[=[
	Requires at least one descendant matching the selector `query` (evaluated with
	`Instance:QueryDescendants`) and returns the first match as the extra value.

	@function Descendant
	@within Predicates
	@param query string -- Selector string passed to `QueryDescendants`.
	@param warningName string? -- Enables warnings on failure; see [doPredicateWarning](#doPredicateWarning).
	@param warnFormatString string? -- Custom warning format; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@return Predicate -- Passes with the first matching descendant as its extra value.
]=]
local Descendant = function(query: string, warningName: string?, warnFormatString: string?): Predicate
	return function(instance: Instance): (boolean, Instance?)
		local descendant = instance:QueryDescendants(query)[1]

		if not descendant then
			doPredicateWarning(instance, warningName, warnFormatString, `Failed to find descendant with query \"{query}\"`)

			return false, nil
		end

		return true, descendant
	end
end

--[=[
	Requires the instance to be a `Model` with a `PrimaryPart` set. Without `primaryPartPredicate`
	the primary part is returned as the extra value. With it, the inner predicate is run against the
	primary part and its extra values are returned *instead of* the part itself.

	```lua
	-- constructor receives (model, trove, primaryPart)
	Predicates.PrimaryPart(nil, "TurretBinder")

	-- constructor receives (model, trove, range: number) read from the primary part
	Predicates.PrimaryPart(Predicates.Attribute("Range", "number", "TurretBinder"), "TurretBinder")
	```

	@function PrimaryPart
	@within Predicates
	@param primaryPartPredicate Predicate? -- Optional predicate to run on the primary part.
	@param warningName string? -- Enables warnings on failure; see [doPredicateWarning](#doPredicateWarning).
	@param warnFormatString string? -- Custom warning format; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@return Predicate -- Passes with the primary part, or the inner predicate's extra values, as extra values.
]=]
local PrimaryPart = function(primaryPartPredicate: Predicate?, warningName: string?, warnFormatString: string?): Predicate
	return function(model: Model): (boolean, BasePart?)
		if not model:IsA("Model") then
			doPredicateWarning(model, warningName, warnFormatString, `Expected Model got \"{model.ClassName}\"`)
			return false, nil
		end

		local primaryPart = model.PrimaryPart
		if not primaryPart then
			doPredicateWarning(model, warningName, warnFormatString, `Model is missing PrimaryPart`)
			return false, nil
		end

		if primaryPartPredicate then
			local success, args = getPredicatePackedArgs(primaryPartPredicate, primaryPart)

			if not success then
				return false, nil
			end			

			return true, unpack(args :: {any})
		end

		return true, primaryPart
	end
end

--[=[
	Passes when the instance is a descendant of `ancestor`. Returns no extra values and never
	warns. Handy inside [ContextGate](#ContextGate) or [Combine](#Combine) when a Binder's own
	`Ancestors` filter is not enough.

	@function IsDescendantOf
	@within Predicates
	@param ancestor Instance -- The required ancestor.
	@return Predicate -- Passes for descendants of `ancestor`.
]=]
local IsDescendantOf = function(ancestor: Instance): Predicate
	return function(instance: Instance): boolean
		return instance:IsDescendantOf(ancestor)
	end
end

--[=[
	Requires a `Humanoid` child and returns it as the extra value. Equivalent to
	`ChildWhichIsA("Humanoid", ...)`.

	@function Humanoid
	@within Predicates
	@param warningName string? -- Enables warnings on failure; see [doPredicateWarning](#doPredicateWarning).
	@param warnFormatString string? -- Custom warning format; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@return Predicate -- Passes with the Humanoid as its extra value.
]=]
local Humanoid = function(warningName: string?, warnFormatString: string?): Predicate
	return ChildWhichIsA("Humanoid", warningName, warnFormatString)
end

--[=[
	Requires the instance to look like a character: a `Humanoid` child and a `BasePart` child named
	`HumanoidRootPart`. Returns the Humanoid, then the HumanoidRootPart, as extra values.

	@function Character
	@within Predicates
	@param warningName string? -- Enables warnings on failure; see [doPredicateWarning](#doPredicateWarning).
	@param warnFormatString string? -- Custom warning format; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@return Predicate -- Passes with `(humanoid, humanoidRootPart)` as extra values.
]=]
local Character = function(warningName: string?, warnFormatString: string?): Predicate
	return Combine { 
		[1] = Humanoid(warningName, warnFormatString),
		[2] = Child("HumanoidRootPart", "BasePart", warningName, warnFormatString),
	}
end

--[=[
	Finds the `Player` an instance belongs to and returns it as the extra value. It checks, in
	order: the instance itself as a character model, the nearest `Model` ancestor as a character
	model, and finally a `Player` ancestor (for things parented under `Players.<Name>`, such as
	items in a Backpack or PlayerGui). Fails when none of those resolves to a player.

	@function Player
	@within Predicates
	@param warningName string? -- Enables warnings on failure; see [doPredicateWarning](#doPredicateWarning).
	@param warnFormatString string? -- Custom warning format; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@return Predicate -- Passes with the owning Player as its extra value.
]=]
local Player = function(warningName: string?, warnFormatString: string?): Predicate
	return function(instance: Instance)
		if instance:IsA("Model") then
			local player: Player = Players:GetPlayerFromCharacter(instance)
			
			if player then
				return true, player
			end
		end
		
		local model = instance:FindFirstAncestorWhichIsA("Model")
		
		if model then
			local player: Player = Players:GetPlayerFromCharacter(model)

			if player then
				return true, player
			end
		end
		
		local player = instance:FindFirstAncestorWhichIsA("Player")
		
		if player then
			return true, player
		end
		
		doPredicateWarning(instance, warningName, warnFormatString, "No player found")
		
		return false
	end
end

--[=[
	Picks a predicate based on where the code runs: `serverPredicate` on the server,
	`clientPredicate` on the client. The chosen predicate's results (including extra values) are
	returned unchanged, so a shared Binder module can demand different things on each side.

	@function ContextGate
	@within Predicates
	@param clientPredicate Predicate -- Used when `RunService:IsServer()` is false.
	@param serverPredicate Predicate -- Used on the server.
	@return Predicate -- Delegates to one of the two predicates.
]=]
local ContextGate = function(clientPredicate: Predicate, serverPredicate: Predicate): Predicate
	return function(instance: Instance): (boolean, ModuleScript?)
		if RunService:IsServer() then
			return serverPredicate(instance)
		else
			return clientPredicate(instance)
		end
	end
end

--[=[
	Warns (when `warningName` is set) if the code is not running in Studio. Note that it **always
	returns `true`**; it flags an instance that should not exist in a live game without blocking
	the bind. Wrap it in your own predicate if you need it to actually reject.

	@function StudioOnly
	@within Predicates
	@param warningName string? -- Enables the "Studio only" warning; see [doPredicateWarning](#doPredicateWarning).
	@param warnFormatString string? -- Custom warning format; defaults to [DEFAULT_WARN_FORMAT_STRING](#DEFAULT_WARN_FORMAT_STRING).
	@return Predicate -- Always passes, warning outside Studio.
]=]
local StudioOnly = function(warningName: string?, warnFormatString: string?): Predicate
	return function(instance: Instance)
		if not RunService:IsStudio() then
			doPredicateWarning(instance, warningName, warnFormatString, "Studio only")
		end
		
		return true
	end
end

--[=[
	@prop T t
	@within Predicates
	@readonly
	The bundled [t](/api/t) runtime type-checking library, re-exported for convenience so you can
	build validators without installing it separately (for example `Predicates.T.numberPositive`).
	See the [TypeValidator](#TypeValidator) caution before using function validators with
	[Attribute](#Attribute).
]=]
return {
	DEFAULT_WARN_FORMAT_STRING = DEFAULT_WARN_FORMAT_STRING,
	doPredicateWarning = doPredicateWarning,
	Predicates = {
		Combine = Combine,
		Attribute = Attribute,
		Attributes = Attributes,
		Child = Child,
		ChildWhichIsA = ChildWhichIsA,
		Descendant = Descendant,
		PrimaryPart = PrimaryPart,
		IsDescendantOf = IsDescendantOf,
		Humanoid = Humanoid,
		Character = Character,
		Player = Player,
		ContextGate = ContextGate,
		StudioOnly = StudioOnly,
	},
	T = T,
}
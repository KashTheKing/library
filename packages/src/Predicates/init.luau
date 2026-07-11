--!strict
const RunService = game:GetService("RunService")
const Players = game:GetService("Players")

--Use Studio Wally Plugin to Install "kashtheking/t"
const T = require(script.Parent.T)

export type Predicate = (any)->(boolean, ...any)

--Predicates to make life easier :)
const DEFAULT_WARN_FORMAT_STRING = "[%s] Predicate failed for %s: %s"

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

local IsDescendantOf = function(ancestor: Instance): Predicate
	return function(instance: Instance): boolean
		return instance:IsDescendantOf(ancestor)
	end
end

local Humanoid = function(warningName: string?, warnFormatString: string?): Predicate
	return ChildWhichIsA("Humanoid", warningName, warnFormatString)
end

local Character = function(warningName: string?, warnFormatString: string?): Predicate
	return Combine { 
		[1] = Humanoid(warningName, warnFormatString),
		[2] = Child("HumanoidRootPart", "BasePart", warningName, warnFormatString),
	}
end

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

local ContextGate = function(clientPredicate: Predicate, serverPredicate: Predicate): Predicate
	return function(instance: Instance): (boolean, ModuleScript?)
		if RunService:IsServer() then
			return serverPredicate(instance)
		else
			return clientPredicate(instance)
		end
	end
end

local StudioOnly = function(warningName: string?, warnFormatString: string?): Predicate
	return function(instance: Instance)
		if not RunService:IsStudio() then
			doPredicateWarning(instance, warningName, warnFormatString, "Studio only")
		end
		
		return true
	end
end

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
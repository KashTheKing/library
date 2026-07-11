--!strict
--[=[
	@class Attributor
]=]
local Attributor = {}

local function getAttributesDict(self: Attributor)
	local dict: {[string]: any} = {}

	for _, attribute in self.Instance:GetAttributes() do
		dict[attribute] = self.Instance:GetAttribute(attribute)
	end

	return dict
end

Attributor.__index = function(self: Attributor, attributeName: string)
	return self.Instance:GetAttribute(attributeName)
end

Attributor.__newindex = function(self: Attributor, attributeName: string, value: any)
	self.Instance:SetAttribute(attributeName, value)
end

Attributor.__call = function(self: Attributor, ...)
	return getAttributesDict(self)
end

Attributor.__tostring = function(self: Attributor)
	return `Attributor<{tostring(self.Instance)}>`
end

--[=[Types]=]--
type self = {
	Instance: Instance,
	Destroy: (self: Attributor)->(),
	[any]: any?
}

export type Attributor = typeof(setmetatable({} :: self, Attributor))

--[=[
	@function new
	@within Attributor
	@param instance T
	@return Attributor
]=]
return function(instance: Instance): Attributor
	local self = {Instance = instance}
	
	local function cleanup()
		local untyped = self :: any
		untyped.Instance = nil --Clear the reference of the instance to allow cleanup
		setmetatable(self, nil)
	end
	
	function self:Destroy()
		if self.Instance then
			cleanup()
		end
	end
	
	instance.Destroying:Connect(cleanup)
	
	return setmetatable(self, Attributor)
end
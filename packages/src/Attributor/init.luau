--!strict
--[=[
	@class Attributor

	Wraps an `Instance` so its attributes read and write like plain table fields. `attributor.Key`
	calls `instance:GetAttribute("Key")`, `attributor.Key = value` calls
	`instance:SetAttribute("Key", value)`, and calling the object (`attributor()`) returns a
	dictionary snapshot of every attribute. Nothing is cached; every access goes straight to the
	instance, so values are always current and writes replicate exactly like normal attributes.

	```lua
	local Attributor = require(path.to.Attributor)

	local stats = Attributor(workspace.Dummy)

	stats.Health = 100        -- workspace.Dummy:SetAttribute("Health", 100)
	stats.Health -= 25        -- reads, then writes 75
	print(stats.Health)       -- 75
	print(stats.MissingKey)   -- nil, the attribute does not exist

	for name, value in stats() do
		print(name, value)    -- every attribute on the instance
	end

	stats:Destroy()           -- optional; also happens when the instance is destroyed
	```

	`Instance` and `Destroy` are real fields on the object, so attributes with those two names cannot
	be reached through the proxy. Writes are subject to the usual `SetAttribute` rules (attribute
	names must be valid and values must be attribute-compatible types) and will error otherwise.

	Installation and guide: [Attributor package page](/docs/packages/attributor).
]=]
local Attributor = {}

--[=[
	@prop Instance Instance
	@within Attributor
	@readonly
	The wrapped instance. Becomes `nil` once the Attributor is destroyed.
]=]

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

--[[ Types ]]
type self = {
	Instance: Instance,
	Destroy: (self: Attributor)->(),
	[any]: any?
}

export type Attributor = typeof(setmetatable({} :: self, Attributor))

--[=[
	Creates an attribute proxy for `instance`. The module itself is this function, so call it as
	`Attributor(instance)`. The proxy connects to `instance.Destroying` and cleans itself up when the
	instance is destroyed, so calling [Attributor:Destroy](#Destroy) yourself is only needed when you
	want to drop the wrapper earlier than that.

	@function new
	@within Attributor
	@param instance Instance -- The instance whose attributes the proxy reads and writes.
	@return Attributor -- A proxy where `proxy.Name` gets and `proxy.Name = value` sets the attribute `Name`.
]=]
return function(instance: Instance): Attributor
	local self = {Instance = instance}

	local function cleanup()
		local untyped = self :: any
		untyped.Instance = nil --Clear the reference of the instance to allow cleanup
		setmetatable(self, nil)
	end

	--[=[
		Detaches the proxy from its instance: clears [Attributor.Instance](#Instance) so the
		instance can be garbage collected and removes the metatable, so later reads return `nil`
		and later writes only touch the now-plain table. Does not destroy or modify the instance.
		Safe to call more than once; also runs automatically when the instance is destroyed.

		@method Destroy
		@within Attributor
	]=]
	function self:Destroy()
		if self.Instance then
			cleanup()
		end
	end
	
	instance.Destroying:Connect(cleanup)
	
	return setmetatable(self, Attributor)
end
--!strict

--[=[
	@class Mechanic
	A system for automatically managing logic applied to tagged instances in Roblox.
	It wraps `CollectionService` to automatically track and configure behaviors on instances
	that match specified criteria such as class name, ancestor containment, or a custom predicate.
]=]

--Services
local CollectionService = game:GetService("CollectionService")

--Classes
local Mechanic = {}
Mechanic.__index = Mechanic

local AppliedMechanic = {}
AppliedMechanic.__index = AppliedMechanic

--Dependencies
local Signal = require(script.Parent.Signal)
local Trove = require(script.Parent.Trove)

--Dependency Types
local ExTypes = require(script.ExternalTypes)
export type Trove = ExTypes.Trove
export type Signal<T...> = ExTypes.Signal<T...>
export type Connection = ExTypes.Connection
export type Constructable<T, U...> = {
	new: {(U...) -> T} | (U...) -> T
}

--[=[
	@type MechanicConfig<T, U> { Shared: T?, Ancestors: {U}?, ClassNames: {string}?, CustomPredicate: ((Instance)->boolean)? }
	A configuration object passed to `Mechanic.new` to define filter and sharing behavior.
]=]
export type MechanicConfig<T, U> = {
	Shared: T?,
	Ancestors: {U}?,
	ClassNames: {string}?,
	CustomPredicate: ((Instance)->boolean)?,
}

type MechanicProperties<T> = {
	Tag: string,
	Applications: {[Instance]: AppliedMechanic<T>},
	Shared: T,
	Ancestors: {Instance},
	ClassNames: {string},
	CustomPredicate: ((Instance)->boolean)?,
	Trove: Trove,
	InstanceAdded: Signal<Instance, AppliedMechanic<T>, Trove>,
	InstanceRemoved: Signal<Instance>
}

export type Mechanic<T> = typeof(setmetatable({} :: MechanicProperties<T>, Mechanic))

type AppliedMechanicProperties<T> = {
	Instance: Instance,
	Shared: T,
	Mechanic: Mechanic<T>,
	Applications: {[Instance]: AppliedMechanic<T>},
	Data: T,
	Trove: Trove,
}

export type AppliedMechanic<T> = typeof(setmetatable({} :: AppliedMechanicProperties<T>, AppliedMechanic))

local function clone(obj: any)
	return table.clone(obj) :: any
end

local function new(obj: any)
	return obj.new()
end

--[=[
	@within AppliedMechanic
	@function new
	@param mechanic Mechanic<T>
	@param instance Instance
	@param data T?
	@return AppliedMechanic<T>
	Constructs a new AppliedMechanic, links cleanup to the Trove, and applies it to the instance.
]=]
function AppliedMechanic.new<T>(mechanic: Mechanic<T>, instance: Instance, data: T?): AppliedMechanic<T>
	local trove = mechanic.Trove:Extend()
	
	local properties: AppliedMechanicProperties<T> = {
		Instance = instance,
		Mechanic = mechanic,
		Applications = mechanic.Applications,
		Shared = mechanic.Shared,
		Data = data or clone(mechanic.Shared) :: T,
		Trove = trove,
	}
	local self: AppliedMechanic<T> = setmetatable(properties, AppliedMechanic)

	local function onAncestryChanged()
		if not mechanic:CanBeApplied(instance) then
			trove:Clean()
		end
	end

	local function onClean()
		mechanic.InstanceRemoved:Fire(instance)
		mechanic.Applications[instance] = nil
	end

	trove:Add(onClean)
	trove:Connect(instance.AncestryChanged, onAncestryChanged)
	trove:AttachToInstance(instance)

	mechanic.Applications[instance] = self
	mechanic.InstanceAdded:Fire(instance, self, trove)

	return self
end

--[=[
	@within AppliedMechanic
	@function GetData
	@return T
	Returns the per-instance data associated with this applied mechanic.
]=]
function AppliedMechanic.GetData<T>(self: AppliedMechanic<T>): T
	return self.Data
end

--[=[
	@within AppliedMechanic
	@function GetShared
	@return T
	Returns the shared mechanic data inherited from the Mechanic config.
]=]
function AppliedMechanic.GetShared<T>(self: AppliedMechanic<T>): T
	return self.Shared
end

--[=[
	@within AppliedMechanic
	@function Destroy
	Cleans up the Trove and removes the mechanic from the application list.
]=]
function AppliedMechanic.Destroy<T>(self: AppliedMechanic<T>)
	self.Trove:Clean()
end

--[=[
	@within Mechanic
	@function new
	@param Tag string
	@param Config MechanicConfig<T, U>?
	@return Mechanic<T>
	Creates a new Mechanic instance with the given tag and optional filtering config.
]=]
function Mechanic.new<T, U>(Tag: string, Config: MechanicConfig<T, U>?): Mechanic<T>
	local Config: MechanicConfig<T, U> = (Config or {})
	local trove = new(Trove) :: Trove

	local properties: MechanicProperties<T> = {
		Tag = Tag,
		Applications = {},
		Shared = Config.Shared or ({} :: any) :: T,
		Ancestors = table.freeze(Config.Ancestors or {}),
		ClassNames = table.freeze(Config.ClassNames or {}),
		CustomPredicate = Config.CustomPredicate,
		Trove = trove,
		InstanceAdded = (trove:Construct(Signal) :: any) :: Signal<Instance, AppliedMechanic<T>, Trove>,
		InstanceRemoved = (trove:Construct(Signal) :: any) :: Signal<Instance>
	}

	local self: Mechanic<T> = setmetatable(properties, Mechanic)

	local function onInstanceAdded(instance: Instance)
		if self:CanBeApplied(instance) then
			self:Apply(instance)
		end
	end

	local function onInstanceRemoved(instance: Instance)
		self:Revoke(instance)
	end

	for _, tagged in CollectionService:GetTagged(self.Tag) do
		coroutine.wrap(onInstanceAdded)(tagged)
	end

	trove:Connect(CollectionService:GetInstanceAddedSignal(self.Tag), onInstanceAdded)
	trove:Connect(CollectionService:GetInstanceRemovedSignal(self.Tag), onInstanceRemoved)

	for _, ancestor in self.Ancestors do
		trove:Connect(ancestor.DescendantAdded, function(instance: Instance)
			if instance:HasTag(self.Tag) then
				onInstanceAdded(instance)
			end
		end)
	end

	return self
end

--[=[
	@within Mechanic
	@function GetApplied
	@param instance Instance
	@return AppliedMechanic<T>?
	Returns the applied mechanic object for an instance, if it exists.
]=]
function Mechanic.GetApplied<T>(self: Mechanic<T>, instance: Instance)
	return self.Applications[instance] :: AppliedMechanic<T>?
end

--[=[
	@within Mechanic
	@function GetInstances
	@return {Instance}
	Returns a list of all instances the mechanic is currently applied to.
]=]
function Mechanic.GetInstances<T>(self: Mechanic<T>): {Instance}
	local instances = {}
	for instance, _ in pairs(self.Applications) do
		table.insert(instances, instance)
	end
	return instances
end

--[=[
	@within Mechanic
	@function CanBeApplied
	@param instance Instance
	@return boolean
	Determines whether a mechanic can be applied to a given instance.
]=]
function Mechanic.CanBeApplied<T>(self: Mechanic<T>, instance: Instance): boolean
	local predicate = self.CustomPredicate
	local classNames = self.ClassNames
	local ancestors = self.Ancestors

	if next(classNames) then
		local valid = false
		for _, className in classNames do
			if instance:IsA(className) then
				valid = true
				break
			end
		end
		if not valid then return false end
	end

	if next(ancestors) then
		local valid = false
		for _, ancestor in ancestors do
			if instance:IsDescendantOf(ancestor) then
				valid = true
				break
			end
		end
		if not valid then return false end
	end
	
	if type(predicate) == "function" and not predicate(instance) then
		return false
	end

	return true
end

--[=[
	@within Mechanic
	@function Apply
	@param instance Instance
	@param data T?
	@return AppliedMechanic<T>
	Forces the mechanic to be applied to the instance, skipping validation checks.
]=]
function Mechanic.Apply<T>(self: Mechanic<T>, instance: Instance, data: T?): AppliedMechanic<T>
	instance:AddTag(self.Tag)

	local existing = self:GetApplied(instance)
	if existing then return existing end

	return AppliedMechanic.new(self, instance, data)
end

--[=[
	@within Mechanic
	@function Revoke
	@param instance Instance
	Removes the tag and revokes the mechanic from the given instance if applied.
]=]
function Mechanic.Revoke<T>(self: Mechanic<T>, instance: Instance)
	instance:RemoveTag(self.Tag)

	local existing = self:GetApplied(instance)
	if existing then
		existing:Destroy()
	end
end

--[=[
	@within Mechanic
	@function OnAdded
	@param callback (Instance, AppliedMechanic<T>, Trove) -> ()
	@return Connection
	Runs the callback for existing and future instances the mechanic is applied to.
]=]
function Mechanic.OnAdded<T>(self: Mechanic<T>, callback: (Instance, AppliedMechanic<T>, Trove)->())
	local connection = self.InstanceAdded:Connect(callback)

	for instance, appliedMechanic in pairs(self.Applications) do
		coroutine.wrap(callback)(instance, appliedMechanic, appliedMechanic.Trove)
	end

	self.Trove:Add(connection)
	return connection
end

--[=[
	@within Mechanic
	@function OnRemoved
	@param callback (Instance) -> ()
	@return Connection
	Connects to the InstanceRemoved signal.
]=]
function Mechanic.OnRemoved<T>(self: Mechanic<T>, callback: (Instance)->())
	local connection = self.InstanceRemoved:Connect(callback)
	self.Trove:Add(connection)
	return connection
end

--[=[
	@within Mechanic
	@function Destroy
	Cleans up the Mechanic and all applied instances.
]=]
function Mechanic.Destroy(self: Mechanic<any>)
	self.Trove:Clean()
end

return {
	new = Mechanic.new,
	
	newConstructor = function<A, B, C, D...>(Tag: string, Config: MechanicConfig<A, B>, Constructable: Constructable<C, D...>)
		local UntypedConstructable = Constructable :: any

		local ConstructorMechanic = Mechanic.new(Tag, Config)

		ConstructorMechanic:OnAdded(function(instance, application, trove)
			application.Data = trove:Construct(UntypedConstructable, instance, trove) :: C
		end)

		return ConstructorMechanic
	end,

	--Same thing as a constructor, just different alias
	bindToClass = function<A, B, C, D...>(Tag: string, Config: MechanicConfig<A, B>, Constructable: Constructable<C, D...>)
		local UntypedConstructable = Constructable :: any

		local ConstructorMechanic = Mechanic.new(Tag, Config)

		ConstructorMechanic:OnAdded(function(instance, application, trove)
			application.Data = trove:Construct(UntypedConstructable, instance, trove) :: C
		end)

		return ConstructorMechanic
	end,
}
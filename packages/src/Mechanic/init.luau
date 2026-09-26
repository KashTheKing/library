--!strict

--[=[
	@class Mechanic
	@deprecated v1.0.0 -- Use [Binder](/api/Binder) instead.

	:::caution Deprecated
	Mechanic is no longer maintained and is kept only for existing projects. Use
	[Binder](/api/Binder) instead; it covers the same use case with a smaller API.
	:::

	Mechanic attaches behaviour to every instance that carries a `CollectionService` tag. It wraps
	`CollectionService:GetInstanceAddedSignal` / `GetInstanceRemovedSignal` and filters the tagged
	instances by class name, by ancestor, or with a custom predicate. Every instance that passes
	the filters gets an [AppliedMechanic](/api/AppliedMechanic) object holding its own per-instance
	`Data` table and a [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) that is cleaned when
	the instance is untagged, destroyed, or moved out of the allowed ancestors.

	The module returns a table with three constructors: `new`, `newConstructor` and `bindToClass`.
	Everything else is a method on the `Mechanic` object they return.

	```lua
	local RunService = game:GetService("RunService")
	local Mechanic = require(path.to.Mechanic)

	local Spinner = Mechanic.new("Spinner", {
		Shared = { Speed = 2 }, -- copied into every instance's Data table
		ClassNames = { "BasePart" },
		Ancestors = { workspace },
	})

	Spinner:OnAdded(function(part, applied, trove)
		local data = applied:GetData()
		trove:Connect(RunService.Heartbeat, function(dt)
			part.CFrame *= CFrame.Angles(0, data.Speed * dt, 0)
		end)
	end)

	Spinner:OnRemoved(function(part)
		print(part.Name, "stopped spinning")
	end)

	-- Later: tag a part manually (also adds the "Spinner" tag) with custom data
	Spinner:Apply(workspace.Windmill, { Speed = 0.5 })
	```

	Depends on Sleitnick's [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) and
	[Signal](https://sleitnick.github.io/RbxUtil/api/Signal/), which Wally installs alongside it.

	Installation and guide: [Mechanic package page](/docs/packages/mechanic).
]=]

--Services
local CollectionService = game:GetService("CollectionService")

--Classes
local Mechanic = {}
Mechanic.__index = Mechanic

--[=[
	@class AppliedMechanic
	@deprecated v1.0.0 -- Part of the deprecated Mechanic package; use [Binder](/api/Binder) instead.

	The object a [Mechanic](/api/Mechanic) creates for each instance it is applied to. You get
	one from [Mechanic:Apply](/api/Mechanic#Apply), [Mechanic:GetApplied](/api/Mechanic#GetApplied)
	or as the second argument of [Mechanic:OnAdded](/api/Mechanic#OnAdded). Do not construct it
	yourself; use `Mechanic:Apply` instead.

	It owns a `Trove` that is cleaned (and the instance removed from the Mechanic) when the
	instance is destroyed, leaves the allowed `Ancestors`, or is revoked. Its `Data` field starts as
	a shallow copy (`table.clone`) of the Mechanic's `Shared` table unless data was passed to
	`Apply`, and `newConstructor` / `bindToClass` replace it with the constructed object.

	```lua
	local applied = Spinner:GetApplied(workspace.Windmill)
	if applied then
		applied:GetData().Speed = 10
		applied.Trove:Add(function() print("cleaned") end)
	end
	```

	This package is no longer maintained; see the deprecation notice on [Mechanic](/api/Mechanic).
]=]
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
--[=[
	@type Constructable { new: (U...) -> T }
	@within Mechanic
	A class table with a `new` constructor, as accepted by `newConstructor` and `bindToClass`. The
	constructor is called through `Trove:Construct` as `new(instance, trove)` and its result becomes
	the AppliedMechanic's `Data`.
]=]
export type Constructable<T, U...> = {
	new: {(U...) -> T} | (U...) -> T
}

--[=[
	@interface MechanicConfig
	@within Mechanic
	.Shared T? -- Table that is shallow-copied into each instance's `Data` (and exposed as `Shared`). Defaults to `{}`.
	.Ancestors {U}? -- Instances the tagged instance must be a descendant of (any one of them). Empty means no ancestor filter.
	.ClassNames {string}? -- Class names the instance must match with `IsA` (any one of them). Empty means no class filter.
	.CustomPredicate ((Instance) -> boolean)? -- Extra check run after the other filters; return `false` to reject the instance.

	Configuration passed to `Mechanic.new` to decide which tagged instances the mechanic applies to
	and what data they start with. Every field is optional; an empty config applies to every
	instance with the tag.
]=]
export type MechanicConfig<T, U> = {
	Shared: T?,
	Ancestors: {U}?,
	ClassNames: {string}?,
	CustomPredicate: ((Instance)->boolean)?,
}

--[=[
	@prop Tag string
	@within Mechanic
	@readonly
	The CollectionService tag this mechanic watches.
]=]
--[=[
	@prop Shared T
	@within Mechanic
	The shared table from the config (or `{}`). Each AppliedMechanic's `Data` starts as a shallow copy of it.
]=]
--[=[
	@prop Applications {[Instance]: AppliedMechanic<T>}
	@within Mechanic
	@readonly
	Every instance the mechanic is currently applied to, mapped to its AppliedMechanic. Prefer `GetApplied` and `GetInstances`.
]=]
--[=[
	@prop Trove Trove
	@within Mechanic
	The mechanic's own Trove. Everything added to it is cleaned by `Destroy`, including every AppliedMechanic.
]=]
--[=[
	@prop InstanceAdded Signal<Instance, AppliedMechanic<T>, Trove>
	@within Mechanic
	@readonly
	Fires when the mechanic is applied to an instance. Receives the instance, its AppliedMechanic and the AppliedMechanic's Trove. `OnAdded` also replays existing applications.
]=]
--[=[
	@prop InstanceRemoved Signal<Instance>
	@within Mechanic
	@readonly
	Fires with the instance after its AppliedMechanic is cleaned (untagged, destroyed, moved out of `Ancestors`, or revoked).
]=]
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

--[=[
	@prop Instance Instance
	@within AppliedMechanic
	@readonly
	The instance this mechanic is applied to.
]=]
--[=[
	@prop Mechanic Mechanic<T>
	@within AppliedMechanic
	@readonly
	The Mechanic that created this object.
]=]
--[=[
	@prop Shared T
	@within AppliedMechanic
	@readonly
	The Mechanic's shared table (the same table for every instance).
]=]
--[=[
	@prop Data T
	@within AppliedMechanic
	Per-instance data. A shallow copy of `Shared`, the `data` passed to `Apply`, or the object built by `newConstructor` / `bindToClass`.
]=]
--[=[
	@prop Trove Trove
	@within AppliedMechanic
	A Trove extended from the Mechanic's Trove. It is cleaned when the instance is destroyed, untagged, leaves the allowed ancestors, or `Destroy` is called; put per-instance connections in it.
]=]
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
	Constructs a new AppliedMechanic for `instance`, registers it in `mechanic.Applications`,
	attaches its Trove to the instance and fires `mechanic.InstanceAdded`. Called by
	`Mechanic:Apply`; you should not need to call it directly because it skips the duplicate check
	and does not add the tag.

	@function new
	@within AppliedMechanic
	@param mechanic Mechanic<T> -- The mechanic being applied.
	@param instance Instance -- The instance to apply it to.
	@param data T? -- Initial `Data`; defaults to a shallow copy of `mechanic.Shared`.
	@return AppliedMechanic<T> -- The new applied mechanic.
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
	Returns the per-instance data associated with this applied mechanic (the same table as
	the `Data` field).

	@method GetData
	@within AppliedMechanic
	@return T -- The per-instance data.
]=]
function AppliedMechanic.GetData<T>(self: AppliedMechanic<T>): T
	return self.Data
end

--[=[
	Returns the shared table inherited from the Mechanic config. It is shared by every instance
	of the mechanic, so changes here affect all of them.

	@method GetShared
	@within AppliedMechanic
	@return T -- The Mechanic's shared table.
]=]
function AppliedMechanic.GetShared<T>(self: AppliedMechanic<T>): T
	return self.Shared
end

--[=[
	Cleans the Trove, removes the instance from the Mechanic's `Applications` and fires
	`InstanceRemoved`. The tag stays on the instance, so the mechanic will be re-applied if the
	instance is re-tagged or `Apply` is called again; use `Mechanic:Revoke` to also remove the tag.

	@method Destroy
	@within AppliedMechanic
]=]
function AppliedMechanic.Destroy<T>(self: AppliedMechanic<T>)
	self.Trove:Clean()
end

--[=[
	Creates a Mechanic for `Tag`. Instances that already have the tag and pass the filters are
	applied immediately (each in its own coroutine); instances tagged later are applied as they
	appear, and instances that lose the tag are revoked. When `Ancestors` is set, tagged instances
	that are later parented under one of the ancestors are picked up too.

	@function new
	@within Mechanic
	@param Tag string -- The CollectionService tag to watch.
	@param Config MechanicConfig<T, U>? -- Filters and shared data; defaults to no filters and `Shared = {}`.
	@return Mechanic<T> -- The new mechanic.
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
	Returns the AppliedMechanic for `instance`, or `nil` if the mechanic is not currently applied
	to it.

	@method GetApplied
	@within Mechanic
	@param instance Instance -- The instance to look up.
	@return AppliedMechanic<T>? -- The applied mechanic, or nil.
]=]
function Mechanic.GetApplied<T>(self: Mechanic<T>, instance: Instance)
	return self.Applications[instance] :: AppliedMechanic<T>?
end

--[=[
	Returns a new array of every instance the mechanic is currently applied to. The order is
	not defined.

	@method GetInstances
	@within Mechanic
	@return {Instance} -- The applied instances.
]=]
function Mechanic.GetInstances<T>(self: Mechanic<T>): {Instance}
	local instances = {}
	for instance, _ in pairs(self.Applications) do
		table.insert(instances, instance)
	end
	return instances
end

--[=[
	Runs the config filters against `instance`: it must `IsA` one of `ClassNames` (if any were
	given), be a descendant of one of `Ancestors` (if any were given), and pass `CustomPredicate`
	(if set). The tag itself is not checked.

	@method CanBeApplied
	@within Mechanic
	@param instance Instance -- The instance to test.
	@return boolean -- Whether the instance passes every filter.
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
	Adds the tag to `instance` and applies the mechanic to it right away, skipping the
	`CanBeApplied` filters. If the mechanic is already applied to the instance the existing
	AppliedMechanic is returned and `data` is ignored.

	@method Apply
	@within Mechanic
	@param instance Instance -- The instance to apply the mechanic to.
	@param data T? -- Initial `Data` for the instance; defaults to a shallow copy of `Shared`.
	@return AppliedMechanic<T> -- The new or existing applied mechanic.
]=]
function Mechanic.Apply<T>(self: Mechanic<T>, instance: Instance, data: T?): AppliedMechanic<T>
	instance:AddTag(self.Tag)

	local existing = self:GetApplied(instance)
	if existing then return existing end

	return AppliedMechanic.new(self, instance, data)
end

--[=[
	Removes the tag from `instance` and, if the mechanic is applied to it, destroys its
	AppliedMechanic (cleaning its Trove and firing `InstanceRemoved`). Safe to call on instances
	the mechanic is not applied to.

	@method Revoke
	@within Mechanic
	@param instance Instance -- The instance to revoke the mechanic from.
]=]
function Mechanic.Revoke<T>(self: Mechanic<T>, instance: Instance)
	instance:RemoveTag(self.Tag)

	local existing = self:GetApplied(instance)
	if existing then
		existing:Destroy()
	end
end

--[=[
	Connects `callback` to `InstanceAdded` and also runs it (in a new coroutine each) for every
	instance the mechanic is already applied to. The callback receives the instance, its
	AppliedMechanic and the AppliedMechanic's Trove; connect per-instance work to that Trove so it
	is cleaned up when the instance goes away. The connection is added to the mechanic's Trove.

	@method OnAdded
	@within Mechanic
	@param callback (Instance, AppliedMechanic<T>, Trove) -> () -- Called with the instance, its AppliedMechanic and that AppliedMechanic's Trove.
	@return Connection -- The signal connection; disconnect it to stop receiving new instances.
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
	Connects `callback` to `InstanceRemoved`, so it runs with the instance whenever an
	AppliedMechanic is cleaned (the instance was untagged, destroyed, moved out of `Ancestors`, or
	revoked). The connection is added to the mechanic's Trove.

	@method OnRemoved
	@within Mechanic
	@param callback (Instance) -> () -- Called with the instance that was removed.
	@return Connection -- The signal connection.
]=]
function Mechanic.OnRemoved<T>(self: Mechanic<T>, callback: (Instance)->())
	local connection = self.InstanceRemoved:Connect(callback)
	self.Trove:Add(connection)
	return connection
end

--[=[
	Cleans the mechanic's Trove: every AppliedMechanic is destroyed (firing `InstanceRemoved` for
	each), the CollectionService connections are disconnected and both signals are destroyed. Tags
	are left on the instances.

	@method Destroy
	@within Mechanic
]=]
function Mechanic.Destroy(self: Mechanic<any>)
	self.Trove:Clean()
end

--[=[
	Creates a Mechanic and, for every instance it is applied to, constructs
	`Constructable.new(instance, trove)` through the AppliedMechanic's Trove and stores the
	result in the AppliedMechanic's `Data`. The constructed object is destroyed with the Trove
	when the instance is removed. This is the closest equivalent to Binder.

	```lua
	local Door = {}
	Door.__index = Door

	function Door.new(model: Model, trove)
		local self = setmetatable({ Model = model, Open = false }, Door)
		trove:Connect(model.ClickDetector.MouseClick, function() self:Toggle() end)
		return self
	end

	function Door.Toggle(self)
		self.Open = not self.Open
	end

	function Door.Destroy(self) end

	local DoorMechanic = Mechanic.newConstructor("Door", { ClassNames = { "Model" } }, Door)
	```

	@function newConstructor
	@within Mechanic
	@param Tag string -- The CollectionService tag to watch.
	@param Config MechanicConfig<A, B> -- Filters and shared data; pass `{}` for none.
	@param Constructable Constructable<C, D...> -- A class table whose `new(instance, trove)` builds the per-instance object.
	@return Mechanic<C> -- The new mechanic; each AppliedMechanic's `Data` is the constructed object.
]=]
--[=[
	Alias of `newConstructor`: identical behaviour under a Binder-style name.

	@function bindToClass
	@within Mechanic
	@param Tag string -- The CollectionService tag to watch.
	@param Config MechanicConfig<A, B> -- Filters and shared data; pass `{}` for none.
	@param Constructable Constructable<C, D...> -- A class table whose `new(instance, trove)` builds the per-instance object.
	@return Mechanic<C> -- The new mechanic; each AppliedMechanic's `Data` is the constructed object.
]=]
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
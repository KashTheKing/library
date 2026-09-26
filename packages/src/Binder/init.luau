--!strict
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Trove = require(script.Parent.Trove)
export type Trove = Trove.Trove
export type Constructable<A> = { new: (any, Trove, ...any) -> A } | ((any, Trove, ...any) -> A)

local Signal = require(script.Parent.Signal)
export type Connection = Signal.Connection
export type Signal<T...> = Signal.Signal<T...>

local Predicates = require(script.Parent.Predicates)
export type Predicate = Predicates.Predicate

--[=[
	@class Binder

	Binds a constructor to Roblox instances for their whole lifetime. A Binder watches the game
	(or a set of ancestors) for instances that match its filters, calls your constructor for each
	one with a dedicated [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/), and cleans that
	Trove up again when the instance is removed, loses its tag, or is unbound manually.

	Filters are combined: an instance has to carry one of the `Tags`, be one of the `ClassNames`,
	sit under one of the `Ancestors` **and** pass the `Predicate`. Any filter you leave out is
	skipped. Values returned by the predicate (after the boolean) are forwarded to your constructor
	after the Trove, which is how the [Predicates](/api/Predicates) factories hand you the
	attribute, child or player they found.

	```lua
	local Binder = require(path.to.Binder)

	local Door = {}
	Door.__index = Door

	function Door.new(instance: Model, trove, openTime: number)
		local self = setmetatable({ Instance = instance, OpenTime = openTime }, Door)

		trove:Connect(instance.PrimaryPart.Touched, function()
			self:Open()
		end)

		return self
	end

	function Door:Open()
		print(`Opening {self.Instance.Name} for {self.OpenTime}s`)
	end

	function Door:Destroy()
		-- called automatically when the door is unbound
	end

	local doors = Binder.new(Door, {
		Tags = { "Door" },
		ClassNames = { "Model" },
		Ancestors = { workspace },
		Predicate = Binder.Predicates.Attribute("OpenTime", "number", "DoorBinder"),
		AutoStart = true,
	})

	doors.InstanceBound:Connect(function(instance, trove, door)
		print("Bound", instance:GetFullName())
	end)
	```

	The module also exposes the whole [Predicates](/api/Predicates) module through its metatable,
	so `Binder.Predicates.Attribute(...)`, `Binder.doPredicateWarning` and `Binder.T` are the same
	values you would get from requiring Predicates directly.

	Installation and guide: [Binder package page](/docs/packages/binder).
]=]
local Binder = {}

--[=[
	@type Constructable { new: (instance: any, trove: Trove, ...any) -> A } | (instance: any, trove: Trove, ...any) -> A
	@within Binder
	What a Binder constructs for each bound instance. Either a table with a `.new` function (a
	typical class module) or a plain function. It is called with the instance, a Trove that is
	cleaned up when the instance is unbound, and any extra values the predicate returned. It must
	return a non-nil value; if the value has a `Destroy` method it is added to the Trove so it is
	destroyed automatically on unbind. If you have nothing to return, return the Trove.
]=]

--[=[
	@type Predicate (any) -> (boolean, ...any)
	@within Binder
	Re-export of [Predicates.Predicate](/api/Predicates#Predicate). Receives the candidate
	instance and returns whether it may be bound, followed by any extra values to pass to the
	constructor.
]=]

--[=[
	@prop Trove Trove
	@within Binder
	@readonly
	The Binder's root Trove. Every per-instance Trove is an extension of it, so cleaning it (which
	is what [Binder:Destroy](#Destroy) does) unbinds every instance and disconnects the signals.
	You may add your own cleanup tasks to it.
]=]

--[=[
	@prop InstanceBound Signal<Instance, Trove, A>
	@within Binder
	@readonly
	Fires after an instance has been bound, whether automatically or through [Binder:Bind](#Bind).
	Receives the instance, the Trove created for it and the value your constructor returned.
]=]

--[=[
	@prop InstanceUnbound Signal<Instance>
	@within Binder
	@readonly
	Fires after an instance has been unbound and its Trove cleaned, whether because it was removed,
	lost its tag, [Binder:Unbind](#Unbind) was called or the Binder was destroyed. Receives the
	instance.
]=]

--Types
export type BinderProperties<A> = {
	Trove: Trove,

	Tags: { string }?,
	ClassNames: { string }?,
	Ancestors: { Instance }?,
	Predicate: Predicate?,
	Priority: number?,

	Constructable: Constructable<A>,
	BoundConstructeds: { [Instance]: any },
	BoundTroves: { [any]: Trove },

	InstanceBound: Signal.Signal<Instance, Trove, A>,
	InstanceUnbound: Signal.Signal<Instance>,

	ManualBindingOnly: boolean,
	RemoveTagsOnCleanup: boolean,
}

export type Binder<A> = typeof(setmetatable({} :: BinderProperties<A>, { __index = Binder, handleTrove = Trove.new() }))

--[=[
	@interface BinderConfig
	@within Binder
	.Tags { string }? -- CollectionService tags. An instance needs at least one of them to bind, and `Bind` adds all of them to the instance. Also drives automatic binding: tagging/untagging an instance binds/unbinds it.
	.ClassNames { string }? -- Class names the instance must match (checked with `IsA`, so superclasses such as `"BasePart"` work).
	.Ancestors { Instance }? -- Only descendants of one of these instances may bind, and only these are watched for `DescendantAdded`/`DescendantRemoving`. When omitted the whole `game` is watched and the instance must be a descendant of `game`.
	.Predicate Predicate? -- Final check run on every candidate. Must return `true` or `false`; extra return values are passed to the constructor after the Trove. Errors inside it are reported and count as `false`.
	.Priority number? -- When set, automatic binds/unbinds are queued and flushed on the next `Heartbeat`, ordered so that lower numbers run first across all Binders. When omitted they run immediately.
	.AutoStart boolean? -- Call `Start` for you right after construction (in a new thread). Cannot be combined with `ManualBindingOnly`.
	.ManualBindingOnly boolean? -- Disable automatic binding entirely: `Start` errors, `Bind` skips the tag/class/ancestor checks (the predicate still runs) and errors instead of returning `nil` when the predicate fails.
	.RemoveTagsOnCleanup boolean? -- Remove every `Tags` entry from the instance when it is unbound. Defaults to `false`.

	Configuration table accepted by [Binder.new](#new). Every field is optional; table fields are
	frozen once passed in and a field with the wrong type raises an error.
]=]
export type BinderConfig<B...> = {
	Tags: { string }?,
	ClassNames: { string }?,
	Ancestors: { Instance }?,
	Predicate: Predicate?,
	Priority: number?,
	AutoStart: boolean?,
	ManualBindingOnly: boolean?,
	RemoveTagsOnCleanup: boolean?,
}

type QueueEntry = {
	index: number,
	thread: () -> () | thread,
}

local Queue: { QueueEntry } = {}
local QueueConnection: RBXScriptConnection?

local function assertConfigValue(v: any, t: string)
	if v == nil then
		return v
	end

	if typeof(v) == t then
		if t == "table" then
			return table.freeze(v)
		end

		return v
	end

	error(`Invalid type passed, expected {t}`, 2)
end

local function flushQueue()
	table.sort(Queue, function(a: QueueEntry, b: QueueEntry)
		return a.index < b.index
	end)

	for i, entry in Queue do
		task.spawn(entry.thread)
	end

	table.clear(Queue)
end

local function ownQueue(trove: Trove)
	QueueConnection = trove:Connect(RunService.Heartbeat, flushQueue) :: any

	trove:Add(function()
		QueueConnection = nil
	end)
end

local function construct<A>(trove: Trove, constructable: Constructable<A>, ...: any): A
	local constructed: any

	local args = { ... }

	local success, err = pcall(function()
		local untypedConstructable = constructable :: any

		local t = type(untypedConstructable)

		if t == "function" then
			constructed = untypedConstructable(unpack(args))
		elseif t == "table" or t == "userdata" then
			if untypedConstructable["new"] then
				constructed = (untypedConstructable["new"] :: any)(unpack(args))
			else
				error("Add a .new constructor method to your constructor", 2)
			end
		end
	end)

	if not success then
		error(err, 2)
	end

	if constructed and constructed["Destroy"] then
		trove:Add(constructed)
	end

	return constructed
end

--[=[
	Creates a Binder that constructs `constructable` for every instance matching `config`.

	What happens next depends on the config:
	- No `config`, or `ManualBindingOnly = true`: nothing is watched. Use [Binder:Bind](#Bind) and
	  [Binder:Unbind](#Unbind) yourself.
	- `AutoStart = true`: [Binder:Start](#Start) is called for you in a new thread, so existing
	  instances are bound shortly after this returns.
	- Otherwise the filters are stored but nothing happens until you call [Binder:Start](#Start).

	@function new
	@within Binder
	@param constructable Constructable<A> -- Class table with a `.new` function, or a plain function, called for each bound instance.
	@param config BinderConfig? -- Filters and behaviour flags; see [BinderConfig](#BinderConfig).
	@return Binder<A> -- The new Binder.
	@error "Invalid config" -- `config` is not a table.
	@error "Invalid type passed, expected <type>" -- A config field has the wrong type.
	@error "Binder cannot have both AutoStart and ManualBindingOnly set to true" -- Both flags were set.
]=]
--Creates a new Binder
function Binder.new<A>(constructable: Constructable<A>, config: BinderConfig<A>?): Binder<A>
	assert(not config or typeof(config) == "table", "Invalid config")

	local tags, classNames, ancestors, predicate, priority, manualBindingOnly, removeTagsOnCleanup, autoStart

	if config then
		tags = assertConfigValue(config.Tags, "table") :: any
		classNames = assertConfigValue(config.ClassNames, "table") :: any
		ancestors = assertConfigValue(config.Ancestors, "table") :: any
		predicate = assertConfigValue(config.Predicate, "function") :: any
		priority = assertConfigValue(config.Priority, "number") :: any
		manualBindingOnly = config.ManualBindingOnly
		removeTagsOnCleanup = config.RemoveTagsOnCleanup
		autoStart = config.AutoStart
	end

	if autoStart and manualBindingOnly then
		error(`Binder cannot have both AutoStart and ManualBindingOnly set to true`, 2)
	end

	local trove = Trove.new()

	local properties: BinderProperties<A> = {
		Trove = trove,

		Tags = tags,
		ClassNames = classNames,
		Ancestors = ancestors,
		Predicate = predicate,
		Priority = priority,

		Constructable = constructable,
		BoundConstructeds = {},
		BoundTroves = {},

		InstanceBound = trove:Construct(Signal :: any),
		InstanceUnbound = trove:Construct(Signal :: any),

		ManualBindingOnly = manualBindingOnly == true,
		RemoveTagsOnCleanup = removeTagsOnCleanup == true,
	}

	local self = setmetatable(properties, {
		__index = Binder,
		handleTrove = trove:Extend(),
	}) :: any

	if not config or manualBindingOnly then
		--Returns a binder that isn't connected to any events
		--Useful for cases where you may want to manually call :HandleInstance()
		return self
	elseif autoStart then
		--Automatically start the binder
		task.spawn(function()
			self:Start()
		end)
	end

	return self
end

--[=[
	Runs the filters against `instance` without binding it. The checks are, in order: `Tags`
	(any one), `ClassNames` (any one, via `IsA`), `Ancestors` (any one, or "is a descendant of
	`game`" when no ancestors are configured) and finally `Predicate`. When the Binder is
	`ManualBindingOnly` the first three checks are skipped and only the predicate runs.

	If a predicate is configured and passes, the second return value is a packed table of the extra
	values the predicate returned; these are what [Binder:Bind](#Bind) unpacks into the constructor.
	A predicate that errors or does not return a boolean first is reported through `error` in a
	separate thread and treated as `false`.

	@method CanBind
	@within Binder
	@param instance Instance -- The instance to test.
	@return boolean -- Whether the instance passes every configured filter.
	@return { any }? -- Packed extra values from the predicate, or nil when there is no predicate.
]=]
--Returns true if the binder can be bound to the given instance, false otherwise
--If true, passes extra arguments returned from the predicate to the constructor
function Binder.CanBind<A>(self: Binder<A>, instance: Instance): (boolean, ...any)
	--Manual binding should add missing tags, not assert them
	if not self.ManualBindingOnly then
		--Check tag
		local hasValidTag = false

		if not self.Tags or #self.Tags == 0 then
			hasValidTag = true
		else
			for _, tag in self.Tags do
				local success, err = pcall(function()
					if instance:HasTag(tag) then
						hasValidTag = true
					end
				end)

				if hasValidTag then
					break
				end
			end
		end

		if not hasValidTag then
			return false
		end

		--Check instance class
		local isValidClass = false

		if not self.ClassNames or #self.ClassNames == 0 then
			isValidClass = true
		else
			for _, className in self.ClassNames do
				if instance:IsA(className) then
					isValidClass = true
					break
				end
			end
		end

		if not isValidClass then
			return false
		end

		--Check instance ancestor
		local isValidAncestor = false

		if not self.Ancestors or #self.Ancestors == 0 then
			isValidAncestor = instance:IsDescendantOf(game)
		else
			for _, ancestor in self.Ancestors do
				if instance:IsDescendantOf(ancestor) then
					isValidAncestor = true
				end
			end
		end

		if not isValidAncestor then
			return false
		end
	end

	--Check predicate function
	--Even if there is manual binding, always use the predicate function if it's there
	if self.Predicate then
		local predicateValid: boolean = false
		local predicateArgs: { any } = {}

		local success, err = pcall(function()
			local predicateResult = { self.Predicate(instance) }
			predicateValid = predicateResult[1]
			predicateArgs = { table.unpack(predicateResult, 2) }
		end)

		if not success then
			task.spawn(error, err :: any, 2)
			return false
		end

		if typeof(predicateValid) ~= "boolean" then
			task.spawn(error, "First value returned was not a boolean, make sure to return true or false" :: any, 2)
			return false
		end

		if not predicateValid then
			return false
		end

		return true, predicateArgs
	end

	return true
end

--[=[
	Returns the Trove that was created for a bound object. Note that the key is the value your
	constructor returned, not the instance; use [Binder:GetBinding](#GetBinding) first if you only
	have the instance. Cleaning this Trove unbinds the object.

	@method GetTrove
	@within Binder
	@param binding A -- The object returned by the constructor for some bound instance.
	@return Trove? -- The object's Trove, or nil if it is not (or no longer) bound.
]=]
function Binder.GetTrove<A>(self: Binder<A>, binding: any): Trove?
	return self.BoundTroves[binding]
end

--[=[
	Returns the object the constructor produced for `instance`.

	@method GetBinding
	@within Binder
	@param instance Instance -- A possibly bound instance.
	@return A? -- The bound object, or nil if the instance is not bound by this Binder.
]=]
function Binder.GetBinding<A>(self: Binder<A>, instance: Instance): A?
	return self.BoundConstructeds[instance]
end

--[=[
	Returns a new array of every instance currently bound by this Binder. The order is not
	defined.

	@method GetInstances
	@within Binder
	@return { Instance } -- All bound instances.
]=]
function Binder.GetInstances<A>(self: Binder<A>): { Instance }
	local instances = {}

	for instance in self.BoundConstructeds do
		table.insert(instances, instance)
	end

	return instances
end

--[=[
	Binds `instance` right now. This is what automatic binding calls internally, and what you call
	yourself on a `ManualBindingOnly` Binder.

	Steps, in order:
	1. If the instance is already bound, a warning is printed and the existing object is returned.
	2. [Binder:CanBind](#CanBind) is run. On failure this returns `nil`, or errors when the Binder
	   is `ManualBindingOnly`.
	3. Every configured tag is added to the instance.
	4. A Trove is extended from [Binder.Trove](#Trove) and the constructable is called with
	   `(instance, trove, ...predicateValues)`. If the result has a `Destroy` method it is added to
	   the Trove. Returning `nil` from the constructable is an error.
	5. [Binder.InstanceBound](#InstanceBound) fires with `(instance, trove, object)`.

	When the Trove is later cleaned (by [Binder:Unbind](#Unbind), removal, or
	[Binder:Destroy](#Destroy)) the tags are removed if `RemoveTagsOnCleanup` is set and
	[Binder.InstanceUnbound](#InstanceUnbound) fires.

	@method Bind
	@within Binder
	@param instance Instance -- The instance to bind.
	@param ... any -- Reserved. Currently ignored; the constructor receives the predicate's extra values instead.
	@return A? -- The constructed object (or the existing one if already bound), or nil if the filters rejected the instance.
	@error "Unable to bind instance" -- The Binder is `ManualBindingOnly` and the predicate rejected the instance.
	@error "Nothing was returned by the constructable..." -- The constructable returned nil.
	@error "Add a .new constructor method to your constructor" -- The constructable is a table without a `new` field.
]=]
function Binder.Bind<A>(self: Binder<A>, instance: Instance, ...: any): A?
	local existingBinding = self:GetBinding(instance)

	if existingBinding then
		warn("Instance was already bound")
		return existingBinding
	end

	local canBind, bindArgs = self:CanBind(instance)

	if not canBind then
		if self.ManualBindingOnly then
			error("Unable to bind instance", 2)
		end

		return nil
	end

	if self.Tags then
		for _, tag in self.Tags do
			instance:AddTag(tag)
		end
	end

	local trove = self.Trove:Extend()

	local binding = construct(trove, self.Constructable, instance, trove, unpack(bindArgs or {}))
	
	if binding == nil then
		error(`Nothing was returned by the constructable. If you don't need to return anything, do \`return trove\``, 2)
	end

	self.BoundConstructeds[instance] = binding
	self.BoundTroves[binding] = trove

	trove:Add(function()
		if self.Tags then
			if self.RemoveTagsOnCleanup then
				for _, tag in self.Tags do
					instance:RemoveTag(tag)
				end
			end
		end

		self.BoundConstructeds[instance] = nil
		self.BoundTroves[binding] = nil

		self.InstanceUnbound:Fire(instance)
	end)

	self.InstanceBound:Fire(instance, trove, binding)

	return binding
end

--[=[
	Unbinds `instance` by cleaning the Trove that was created for it. This destroys the bound object
	(if it has a `Destroy` method), disconnects anything you connected through that Trove, removes
	the tags when `RemoveTagsOnCleanup` is set and fires [Binder.InstanceUnbound](#InstanceUnbound).
	Does nothing if the instance is not bound. The instance itself is not destroyed.

	@method Unbind
	@within Binder
	@param instance Instance -- The instance to unbind.
]=]
function Binder.Unbind<A>(self: Binder<A>, instance: Instance)
	local binding = self:GetBinding(instance)

	if not binding then
		return
	end

	local trove = self.BoundTroves[binding]

	if not trove then
		warn("Trove couldn't be found for binding")
		return
	end

	trove:Clean()
end

--[=[
	Starts automatic binding. Any previous listeners are stopped first, so calling this twice is
	safe. Not needed when the Binder was created with `AutoStart = true`.

	Listeners connected:
	- For each `Tags` entry: `CollectionService:GetInstanceAddedSignal` binds and
	  `GetInstanceRemovedSignal` unbinds.
	- For each `Ancestors` entry: `DescendantAdded` binds and `DescendantRemoving` unbinds, and
	  every existing descendant is bound in its own thread.
	- With no `Ancestors`, every existing descendant of `game` is tried once (in its own thread);
	  afterwards only tag changes trigger binds, so give the Binder `Tags` or `Ancestors` if you
	  want to react to new instances.

	Every candidate still has to pass [Binder:CanBind](#CanBind), so tag and ancestor listeners
	can be combined freely.

	**Priority queue.** Without a `Priority`, binds and unbinds happen as soon as the event fires.
	With a `Priority`, each bind/unbind is appended to a queue shared by all Binders in the same
	VM; on the next `Heartbeat` the queue is sorted ascending by priority and flushed, so a Binder
	with priority `1` binds before one with priority `2` even when their instances appear in the
	same frame. The first Binder that needs the queue owns its `Heartbeat` connection until that
	Binder is stopped or destroyed, after which the next queued bind claims it again.

	@method Start
	@within Binder
	@error "Binder is manual only because ManualBindingOnly is set to true..." -- The Binder was created with `ManualBindingOnly`.
]=]
--Starts automatic handling
function Binder.Start<A>(self: Binder<A>): ()
	assert(
		self.ManualBindingOnly == false,
		"Binder is manual only because ManualBindingOnly is set to true, use binder:Bind()/binder:Unbind() instead."
	)

	self:Stop()

	local meta = getmetatable(self)
	local handleTrove =
		assert(meta.handleTrove :: Trove, "Binder metatable is missing handleTrove, was the metatable overridden?")

	local tags = self.Tags
	local ancestors = self.Ancestors
	local manualBindingOnly = self.ManualBindingOnly

	local handleInstance
	local queueBind

	local function _handleInstance(instance: Instance, wasAdded: boolean): ()
		if wasAdded then
			self:Bind(instance)
		else
			self:Unbind(instance)
		end
	end

	function handleInstance(instance: Instance, wasAdded: boolean): ()
		if self.Priority then
			queueBind(instance, wasAdded)
		else
			_handleInstance(instance, wasAdded)
		end
	end

	function queueBind(instance: Instance, wasAdded: boolean): ()
		local queueEntry: QueueEntry = {
			index = self.Priority :: number,
			thread = function()
				_handleInstance(instance, wasAdded)
			end,
		}

		table.insert(Queue, queueEntry)

		if not QueueConnection then
			--This binder will take control of the QueueConnection if one hasn't yet
			ownQueue(handleTrove)
		end
	end

	if tags then
		for _, tag in tags do
			handleTrove:Connect(CollectionService:GetInstanceRemovedSignal(tag), function(instance: Instance)
				handleInstance(instance, false)
			end)

			if not manualBindingOnly then
				handleTrove:Connect(CollectionService:GetInstanceAddedSignal(tag), function(instance: Instance)
					handleInstance(instance, true)
				end)
			end
		end
	end

	if ancestors then
		for _, ancestor in ancestors do
			handleTrove:Connect(ancestor.DescendantRemoving, function(instance: Instance)
				handleInstance(instance, false)
			end)

			if not manualBindingOnly then
				handleTrove:Connect(ancestor.DescendantAdded, function(instance: Instance)
					handleInstance(instance, true)
				end)

				for _, instance in ancestor:GetDescendants() do
					task.spawn(function()
						handleInstance(instance, true)
					end)
				end
			end
		end
	else
		if not manualBindingOnly then
			for _, instance in game:GetDescendants() do
				task.spawn(function()
					handleInstance(instance, true)
				end)
			end
		end
	end
end

--[=[
	Disconnects the listeners created by [Binder:Start](#Start) so no new instances are bound or
	unbound automatically. Instances that are already bound stay bound; use [Binder:Destroy](#Destroy)
	to clean those up as well. Safe to call on a Binder that was never started.

	@method Stop
	@within Binder
]=]
--Stops the binder from automatically binding
--Does NOT clean up any bound instances, use Destroy() for that
function Binder.Stop<A>(self: Binder<A>): ()
	local meta = getmetatable(self)
	local handleTrove =
		assert(meta.handleTrove :: Trove, "Binder metatable is missing handleTrove, was the metatable overridden?")
	handleTrove:Clean()
end

--[=[
	Destroys the Binder by cleaning [Binder.Trove](#Trove). This stops automatic binding, unbinds
	every bound instance (firing [Binder.InstanceUnbound](#InstanceUnbound) for each) and destroys
	the `InstanceBound`/`InstanceUnbound` signals. The Binder should not be used afterwards.

	@method Destroy
	@within Binder
]=]
--Destroys the Binder
function Binder.Destroy<A>(self: Binder<A>): ()
	self.Trove:Clean()
end

return setmetatable({ new = Binder.new }, { __index = Predicates })

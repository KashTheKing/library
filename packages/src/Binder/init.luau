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

local Binder = {}

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

function Binder.GetTrove<A>(self: Binder<A>, binding: any): Trove?
	return self.BoundTroves[binding]
end

function Binder.GetBinding<A>(self: Binder<A>, instance: Instance): A?
	return self.BoundConstructeds[instance]
end

function Binder.GetInstances<A>(self: Binder<A>): { Instance }
	local instances = {}

	for instance in self.BoundConstructeds do
		table.insert(instances, instance)
	end

	return instances
end

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

--Stops the binder from automatically binding
--Does NOT clean up any bound instances, use Destroy() for that
function Binder.Stop<A>(self: Binder<A>): ()
	local meta = getmetatable(self)
	local handleTrove =
		assert(meta.handleTrove :: Trove, "Binder metatable is missing handleTrove, was the metatable overridden?")
	handleTrove:Clean()
end

--Destroys the Binder
function Binder.Destroy<A>(self: Binder<A>): ()
	self.Trove:Clean()
end

return setmetatable({ new = Binder.new }, { __index = Predicates })

--!strict

--[=[
	@class StateManager
	@deprecated v1.0.0 -- No longer maintained; kept for existing projects. There is no direct replacement.

	:::caution Deprecated
	StateManager is no longer maintained and is kept only for existing projects. There is no
	direct replacement in this library.
	:::

	A small finite state machine. You build named [State](/api/State) objects, give each one
	`OnEnter` / `OnExit` callbacks, and hand them to a StateManager which keeps exactly one of them
	current. Each State carries a [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) that is
	cleaned every time the state is exited, so anything you connect or create while a state is
	active is torn down automatically when you leave it.

	The module returns a table of functions: `new`, `newState`, `LoadStates`, `MatchesName` and
	`IsChildOf`. Everything else is a method on the `StateManager` or `State` objects.

	```lua
	local RunService = game:GetService("RunService")
	local StateManager = require(path.to.StateManager)

	local Lobby = StateManager.newState("Lobby")
	Lobby:OnEnter(function(manager, trove, lastState)
		print("Entered Lobby from", lastState) -- lastState is nil the first time
		trove:Add(task.delay(10, function()
			manager:ChangeState("Round")
		end))
	end)

	local Round = StateManager.newState("Round")
	Round:OnEnter(function(manager, trove)
		trove:Connect(RunService.Heartbeat, function(dt)
			-- runs only while Round is the current state
		end)
	end)
	Round:OnExit(function()
		print("Round over")
	end)

	local manager = StateManager.new({
		States = { Lobby, Round },
		DefaultState = "Lobby",
	})

	manager.StateChanged:Connect(function(name)
		print("Current state is now", name)
	end)
	```

	Depends on Sleitnick's [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) and
	[Signal](https://sleitnick.github.io/RbxUtil/api/Signal/), which Wally installs alongside it.

	**Credits:** [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) and [Signal](https://sleitnick.github.io/RbxUtil/api/Signal/) are by [sleitnick](https://github.com/Sleitnick) ([sleitnick's RbxUtil](https://sleitnick.github.io/RbxUtil/)). Wally installs both.

	Installation and guide: [StateManager package page](/docs/packages/state-manager).
]=]

--Dependencies
local Signal = require(script.Parent.Signal)
local Trove = require(script.Parent.Trove)

--Dependency Types
local ExTypes = require(script.ExternalTypes)

--State
--[=[
	@class State
	@deprecated v1.0.0 -- Part of the deprecated StateManager package; no longer maintained.

	One named state of a [StateManager](/api/StateManager). Create one with
	`StateManager.newState(name)` (or `require` a ModuleScript that returns one, see
	[LoadStates](/api/StateManager#LoadStates)), attach callbacks with `OnEnter` / `OnExit`, and
	pass it in the `States` list of `StateManager.new`. You can also get one back from
	`StateManager:GetState`.

	A State owns a `Trove` that is cleaned each time the state is exited, so use it for anything
	that should only live while the state is active.

	```lua
	local Round = StateManager.newState("Round")

	Round:OnEnter(function(manager, trove, lastState)
		local timer = trove:Add(Instance.new("Sound")) -- destroyed on exit
	end)
	```

	This package is no longer maintained; see the deprecation notice on
	[StateManager](/api/StateManager).
]=]
local State = {}
State.__index = State

--[=[
	@prop Name string
	@within State
	@readonly
	The name given to `newState`. `StateManager:GetState` and `ChangeState` look states up by it.
]=]
--[=[
	@prop Entered Signal<StateManager, Trove, string?>
	@within State
	@readonly
	Fires (deferred) after this state becomes current. Receives the StateManager, this state's `Trove` and the previous state's name (or nil). `OnEnter` connects to it.
]=]
--[=[
	@prop Exited Signal<>
	@within State
	@readonly
	Fires with no arguments right after this state is exited and its `Trove` has been cleaned. `OnExit` connects to it.
]=]
--[=[
	@prop Trove Trove
	@within State
	Cleaned every time the state is exited (and when the StateManager is destroyed). The same Trove is passed to `OnEnter` callbacks.
]=]
export type StateProperties = {
	Name: string,
	Entered: ExTypes.Signal<StateManager, ExTypes.Trove, string?>,
	Exited: ExTypes.Signal<>,
	Trove: ExTypes.Trove,
	_Trove: ExTypes.Trove,
}

export type State = typeof(setmetatable({} :: StateProperties, State))

local function new(t: any)
	return t.new()
end

--[=[
	Creates a new [State](/api/State) called `name` with fresh `Entered` / `Exited` signals and an
	empty `Trove`. Names should be unique within one StateManager because `GetState` returns the
	first match.

	@function newState
	@within StateManager
	@param name string -- The state's name, used by `ChangeState` and `GetState`.
	@return State -- The new state.
]=]
function State.new(name: string): State
	local _trove = new(Trove) :: ExTypes.Trove
	
	local properties: StateProperties = {
		Name = name,
		_Trove = _trove,
		Trove = _trove:Extend(),
		Entered = _trove:Construct(Signal),
		Exited = _trove:Construct(Signal),
	}

	local self: State = setmetatable(properties, State)

	return self
end

--[=[
	Connects `func` to this state's `Entered` signal. It runs (deferred with `task.defer`, after
	`StateManager.StateChanged` has fired) every time the state becomes current, receiving:

	1. `stateManager` - the StateManager that switched to this state;
	2. `trove` - this state's `Trove`, cleaned when the state is exited; connect and create
	   everything state-specific through it;
	3. `lastState` - the name of the state that was current before, or `nil` if there was none.

	@method OnEnter
	@within State
	@param func (stateManager: StateManager, trove: Trove, lastState: string?) -> () -- Called each time the state is entered.
	@return Connection -- The signal connection; disconnect it to stop listening.
]=]
function State.OnEnter(self: State, func: (stateManager: StateManager, trove: ExTypes.Trove, lastState: string?)->()): ExTypes.Connection
	return self.Entered:Connect(func)
end

--[=[
	Connects `func` to this state's `Exited` signal. It runs synchronously, with no arguments,
	every time the state stops being current (from `ChangeState` or `ExitCurrent`), after the
	state's `Trove` has already been cleaned.

	@method OnExit
	@within State
	@param func () -> () -- Called each time the state is exited.
	@return Connection -- The signal connection; disconnect it to stop listening.
]=]
function State.OnExit(self: State, func: ()->()): ExTypes.Connection
	return self.Exited:Connect(func)
end

--StateManager
local StateManager = {}
StateManager.__index = StateManager

--StateManager Types
--[=[
	@prop CurrentState State?
	@within StateManager
	@readonly
	The state that is currently active, or `nil` after `ExitCurrent` or before the default state is entered.
]=]
--[=[
	@prop Trove Trove
	@within StateManager
	Holds every state's `Trove` and the `StateChanged` signal; `Destroy` destroys it.
]=]
--[=[
	@prop States {State}
	@within StateManager
	@readonly
	The list of states passed in the config.
]=]
--[=[
	@prop StateChanged Signal<string?>
	@within StateManager
	@readonly
	Fires (deferred) with the new state's name whenever `ChangeState` switches state, just before that state's `Entered` signal.
]=]
export type StateManagerProperties = {
	CurrentState: State?,
	Trove: ExTypes.Trove,
	States: {State},
	StateChanged: ExTypes.Signal<string?>
}

export type StateManager = typeof(setmetatable({} :: StateManagerProperties, StateManager))

--[=[
	@interface StateManagerConfig
	@within StateManager
	.States {State} -- The states this manager can switch between; each one's `Trove` is added to the manager's Trove.
	.DefaultState string? -- Name of a state in `States` to enter as soon as the manager is created.

	Configuration passed to `StateManager.new`.
]=]
export type StateManagerConfig = {
	States: {State},
	DefaultState: string?,
}

--[=[
	Creates a StateManager over the given states. Each state's `Trove` is added to the manager's
	Trove so `Destroy` cleans them all. If `DefaultState` is set, `ChangeState(DefaultState)` is
	called immediately in a new thread (`task.spawn`), so a wrong name errors in that thread rather
	than in the caller.

	@function new
	@within StateManager
	@param Config StateManagerConfig -- The states and optional default state.
	@return StateManager -- The new manager.
	@error "Config must be a table" -- `Config` is not a table.
	@error "States field must be a table" -- `Config.States` is not a table.
	@error "DefaultState must be a string" -- `Config.DefaultState` is set but not a string.
]=]
function StateManager.new(Config: StateManagerConfig): StateManager
	if type(Config) ~= "table" then
		error("Config must be a table", 2)
	end
	
	if type(Config.States) ~= "table" then
		error("States field must be a table", 2)
	end
	
	if Config.DefaultState and type(Config.DefaultState) ~= "string" then
		error("DefaultState must be a string", 2)
	end
	
	local trove = new(Trove) :: ExTypes.Trove
	
	for _, state in pairs(Config.States) do
		trove:Add(state.Trove)
	end
	
	local properties: StateManagerProperties = {
		Trove = trove,
		States = Config.States,
		StateChanged = trove:Construct(Signal),
	}
	
	local self: StateManager = setmetatable(properties, StateManager)
	
	if Config.DefaultState then
		task.spawn(function()
			self:ChangeState(Config.DefaultState)
		end)
	end
	
	return self
end

--[=[
	Returns the first state in `States` whose `Name` equals `name`. Errors if there is none, so use
	it only with names you know exist.

	@method GetState
	@within StateManager
	@param name string -- The state's name.
	@return State -- The matching state.
	@error State: "<name>" doesn't exist -- No state in `States` has that name.
]=]
function StateManager.GetState(self: StateManager, name: string): State
	for _, state in self.States do
		if state.Name == name then
			return state :: State
		end
	end
	
	error(`State: "{name}" doesn't exist`, 2)
end

--[=[
	Leaves the current state without entering another one: `CurrentState` becomes `nil`, the old
	state's `Trove` is cleaned and its `Exited` signal fires synchronously. `StateChanged` does not
	fire. Does nothing (and returns `nil`) when there is no current state.

	@method ExitCurrent
	@within StateManager
	@return string? -- The name of the state that was exited, or nil if there was none.
]=]
function StateManager.ExitCurrent(self: StateManager): string?
	local current = self.CurrentState
	
	self.CurrentState = nil
	
	if current then
		local trove = current.Trove
		
		if trove then
			trove:Clean()
		end
		
		current.Exited:Fire()
		
		return current.Name
	end
	
	return nil
end

--[=[
	Switches to the state called `stateName`. In order:

	1. Errors if that state is already current.
	2. Calls `ExitCurrent` (cleans the old state's Trove and fires its `Exited` synchronously).
	3. Looks the new state up with `GetState` (errors if it does not exist; the old state has
	   already been exited at this point, leaving `CurrentState` nil).
	4. Sets `CurrentState`, then on the next `task.defer` step fires `StateChanged(stateName)`
	   followed by the new state's `Entered(self, state.Trove, lastStateName)`.

	Because the enter callbacks are deferred, code right after `ChangeState` runs before any
	`OnEnter` callback does.

	@method ChangeState
	@within StateManager
	@param stateName string -- Name of the state to enter.
	@error "<stateName> is already the current state" -- The named state is already current.
	@error State: "<stateName>" doesn't exist -- No state in `States` has that name.
]=]
function StateManager.ChangeState(self: StateManager, stateName: string)
	if self.CurrentState and self.CurrentState.Name == stateName then
		error(`{stateName} is already the current state`)
	end
	
	local lastState = self:ExitCurrent()
	
	local newState = self:GetState(stateName)
	self.CurrentState = newState
	
	task.defer(function()
		self.StateChanged:Fire(stateName)
		newState.Entered:Fire(self, newState.Trove :: ExTypes.Trove, lastState)
	end)
end

--[=[
	Destroys the manager's Trove, which cleans every state's `Trove` and destroys the
	`StateChanged` signal. `Exited` signals are not fired and `CurrentState` is left as is; call
	`ExitCurrent` first if you want exit callbacks to run.

	@method Destroy
	@within StateManager
]=]
function StateManager.Destroy(self: StateManager)
	self.Trove:Destroy()
end

--Utility method for loading parented states from an instance
--[=[
	Requires every `ModuleScript` under `parent` (all descendants, unless `predicate` rejects
	them) and collects what they return as a list of States for `StateManager.new`. Each module is
	expected to return a State made with `newState`. A module that errors while being required is
	skipped and the error is reported in a separate thread, so one broken state does not stop the
	others from loading. Requiring modules can yield if they do.

	```lua
	local states = StateManager.LoadStates(script.States, StateManager.IsChildOf(script.States))
	local manager = StateManager.new({ States = states, DefaultState = "Lobby" })
	```

	@function LoadStates
	@within StateManager
	@param parent Instance -- The instance whose descendant ModuleScripts are loaded.
	@param predicate ((ModuleScript) -> boolean)? -- Optional filter; return `false` to skip a module. See `MatchesName` and `IsChildOf`.
	@return {State} -- The states returned by the modules that loaded successfully.
]=]
local function LoadStates(parent: Instance, predicate: ((ModuleScript)->boolean)?)
	local States: {State} = {}
	
	for _, descendant in parent:GetDescendants() do
		if descendant:IsA("ModuleScript") then
			if predicate and not predicate(descendant) then
				continue
			end
			
			local state: State
			
			local success, err = pcall(function()
				state = require(descendant) :: State
			end)
			
			if success then
				table.insert(States, state)
			else
				task.spawn(function()
					error(`State {descendant.Name} could not be loaded: {err}`, 2)
				end)
			end
		end
	end
	
	return States
end

--[=[
	Builds a predicate for `LoadStates` that accepts ModuleScripts whose `Name` matches the Lua
	string pattern `name` (via `string.match`), e.g. `MatchesName("State$")`.

	@function MatchesName
	@within StateManager
	@param name string -- A Lua string pattern to match against `ModuleScript.Name`.
	@return (ModuleScript) -> boolean -- The predicate.
]=]
local function MatchesName(name: string): (ModuleScript)->boolean
	return function(moduleScript: ModuleScript)
		return moduleScript.Name:match(name) and true or false
	end
end

--[=[
	Builds a predicate for `LoadStates` that accepts only ModuleScripts that are direct children of
	`parent`, which limits `LoadStates` to one level instead of all descendants.

	@function IsChildOf
	@within StateManager
	@param parent Instance -- The required parent.
	@return (ModuleScript) -> boolean -- The predicate.
]=]
local function IsChildOf(parent: Instance): (ModuleScript)->boolean
	return function(moduleScript: ModuleScript)
		return moduleScript.Parent == parent
	end
end

return {
	new = StateManager.new,
	newState = State.new,
	LoadStates = LoadStates,
	MatchesName = MatchesName,
	IsChildOf = IsChildOf,
}
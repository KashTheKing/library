--!strict

--Dependencies
local Signal = require(script.Parent.Signal)
local Trove = require(script.Parent.Trove)

--Dependency Types
local ExTypes = require(script.ExternalTypes)

--State
local State = {}
State.__index = State

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

function State.OnEnter(self: State, func: (stateManager: StateManager, trove: ExTypes.Trove, lastState: string?)->()): ExTypes.Connection
	return self.Entered:Connect(func)
end

function State.OnExit(self: State, func: ()->()): ExTypes.Connection
	return self.Exited:Connect(func)
end

--StateManager
local StateManager = {}
StateManager.__index = StateManager

--StateManager Types
export type StateManagerProperties = {
	CurrentState: State?,
	Trove: ExTypes.Trove,
	States: {State},
	StateChanged: ExTypes.Signal<string?>
}

export type StateManager = typeof(setmetatable({} :: StateManagerProperties, StateManager))

export type StateManagerConfig = {
	States: {State},
	DefaultState: string?,
}

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

function StateManager.GetState(self: StateManager, name: string): State
	for _, state in self.States do
		if state.Name == name then
			return state :: State
		end
	end
	
	error(`State: "{name}" doesn't exist`, 2)
end

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

function StateManager.Destroy(self: StateManager)
	self.Trove:Destroy()
end

--Utility method for loading parented states from an instance
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

local function MatchesName(name: string): (ModuleScript)->boolean
	return function(moduleScript: ModuleScript)
		return moduleScript.Name:match(name) and true or false
	end
end

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
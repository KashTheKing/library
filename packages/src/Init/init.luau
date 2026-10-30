--!strict
--[=[
	@class Init

	A module loader for Roblox games. You point Init at folders, and it requires every module in
	them in a fixed order, calls their `Init` and `Start` methods, and wires up the methods you
	would otherwise connect by hand (`OnPlayerAdded`, `OnHeartbeat`, `OnCharacterAdded`, ...).

	One Script on the server and one LocalScript on the client boot the whole game:

	```lua
	-- ServerScriptService/InitServer (Script)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")

	local Init = require(ReplicatedStorage.Packages.Init)

	Init.start({
		{ Folders = { ReplicatedStorage.Network } },
		{ Folders = { ReplicatedStorage.Services, ServerScriptService.Services }, Predicate = Init.matchesName("Service$") },
		{ Folders = { ReplicatedStorage.Binders.Shared, ServerScriptService.Binders } },
	})
	```

	A module Init loads is a plain table. Every method is optional:

	```lua
	local PointsService = {}

	function PointsService.Init(self: PointsService)
		self.Points = {} -- set up your own state; don't wait for other modules here
	end

	function PointsService.Start(self: PointsService)
		-- every module has finished Init, so it's safe to use them
	end

	function PointsService.OnPlayerAdded(self: PointsService, player: Player)
		self.Points[player] = 0
	end

	return PointsService
	```

	See [the lifecycle](https://kashtheking.com/init/docs/guides/lifecycle) for the exact order things run in.
]=]
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DefaultSettings = require(script.Settings)
local Promise = require(script.Promise)

--[=[
	@type Settings Settings
	@within Init

	Every option with its default lives in
	[`Settings.luau`](https://github.com/KashTheKing/init/blob/main/src/Init/Settings.luau) and on the
	[settings page](https://kashtheking.com/init/docs/guides/settings).
]=]
export type Settings = DefaultSettings.Settings

--[=[
	@interface Entry
	@within Init
	.Folders { Instance } -- where to look; every ModuleScript inside them (at any depth) is a candidate
	.Predicate ((module: ModuleScript) -> boolean)? -- only load modules this returns `true` for, e.g. [Init.matchesName](#matchesName)
	.Order number? -- only used when entries are a dictionary (the old Entries-module format): lower runs first

	One group of modules to load. A ModuleScript inside another ModuleScript is never loaded on its
	own: it belongs to its parent, which can `require` it.
]=]
export type Entry = {
	Folders: { Instance },
	Predicate: ((module: ModuleScript) -> boolean)?,
	Order: number?,
}

--[=[
	@type Entries { Entry } | { [string]: Entry }
	@within Init

	A list of entries, loaded in list order. A dictionary of named entries (the format of the old
	`SharedEntries`/`ServerEntries` modules) also works and is sorted by each entry's `Order`.
]=]
export type Entries = { Entry } | { [string]: Entry }

--[=[
	@type Modules { [string]: any }
	@within Init

	Every loaded module's returned value, by the ModuleScript's name.
]=]
export type Modules = { [string]: any }

type Loaded = { name: string, value: any }

local Init = {}

local FIXED_STEP = 1 / 60 -- the Step method's rate
local MAX_FRAME = 0.25 -- a frame longer than this (a hitch) is counted as this, so Step can't spiral

local REALM = if RunService:IsServer() then "Server" else "Client"

local started = false
local stepCallbacks: { (dt: number) -> () } = {}

-- An error in the Output that doesn't stop the code that found it
local function report(message: string)
	task.spawn(error, `[Init] {message}`, 0)
end

local function round(seconds: number): number
	return math.floor(seconds * 1000 + 0.5) / 1000
end

local function resolveSettings(overrides: { [string]: any }?): Settings
	local settings = table.clone(DefaultSettings) :: any
	for key, value in (overrides or {}) :: { [string]: any } do
		if (DefaultSettings :: any)[key] == nil then
			error(`[Init] "{key}" isn't a setting. The valid settings are in Init/Settings.`, 3)
		end
		settings[key] = value
	end
	return settings
end

local function orderEntries(entries: Entries): { Entry }
	for name, entry in entries :: { [any]: Entry } do
		if type(entry) ~= "table" or type(entry.Folders) ~= "table" then
			error(`[Init] Entry {name} needs a Folders list, like \{ Folders = \{ ReplicatedStorage.Services } }`, 3)
		end
	end

	local list = entries :: { Entry }
	if #list > 0 or next(entries) == nil then
		return list
	end

	-- A dictionary of named entries: sort by Order, then by name so equal Orders are stable
	local names = {}
	for name in entries :: { [string]: Entry } do
		table.insert(names, name)
	end
	local named = entries :: { [string]: Entry }
	table.sort(names, function(a, b)
		local orderA, orderB = named[a].Order or 0, named[b].Order or 0
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a < b
	end)

	local sorted = {}
	for _, name in names do
		table.insert(sorted, named[name])
	end
	return sorted
end

local function isInsideModule(module: Instance, folder: Instance): boolean
	local parent = module.Parent
	while parent and parent ~= folder do
		if parent:IsA("ModuleScript") then
			return true
		end
		parent = parent.Parent
	end
	return false
end

local function collect(entry: Entry, settings: Settings, seen: { [Instance]: boolean }): { ModuleScript }
	local found: { ModuleScript } = {}
	for _, folder in entry.Folders do
		for _, module in folder:GetDescendants() do
			if
				not module:IsA("ModuleScript")
				or seen[module]
				or isInsideModule(module, folder)
				or module:GetAttribute(settings.IgnoreAttribute)
			then
				continue
			end
			if entry.Predicate then
				local ok, result = pcall(entry.Predicate, module)
				if not ok then
					report(`The Predicate errored on {module:GetFullName()}, so it was skipped: {result}`)
					continue
				elseif result ~= true then
					continue
				end
			end
			seen[module] = true
			table.insert(found, module)
		end
	end

	-- Lower Priority first; equal priorities keep their place in the tree (table.sort isn't stable)
	local position = {}
	for index, module in found do
		position[module] = index
	end
	local function priority(module: ModuleScript): number
		return tonumber(module:GetAttribute(settings.PriorityAttribute)) or settings.DefaultPriority
	end
	table.sort(found, function(a, b)
		local priorityA, priorityB = priority(a), priority(b)
		if priorityA ~= priorityB then
			return priorityA < priorityB
		end
		return position[a] < position[b]
	end)

	return found
end

local function load(module: ModuleScript): (boolean, any)
	local ok, result = pcall(require, module)
	if not ok then
		if tostring(result):find("exactly one value") then
			report(
				`{module:GetFullName()} must return exactly one value (end it with a line like "return {module.Name}")`
			)
		else
			report(`{module:GetFullName()} errored while loading: {result}`)
		end
	end
	return ok, result
end

-- A method only exists if indexing it works and gives a function (modules may return anything)
local function getMethod(value: any, name: string): ((...any) -> ...any)?
	if type(value) ~= "table" then
		return nil
	end
	local ok, method = pcall(function()
		return value[name]
	end)
	return if ok and type(method) == "function" then method else nil
end

-- Runs Init or Start in its own thread. The promise settles when it returns or errors, or rejects
-- after `timeout`; a timed-out method keeps running, Init just stops waiting for it.
local function call(item: Loaded, methodName: string, timeout: number): any
	local method = getMethod(item.value, methodName)
	if not method then
		return nil
	end
	return Promise.new(function(resolve, reject)
		task.spawn(function()
			local ok, err = xpcall(method, debug.traceback, item.value)
			if ok then
				resolve()
			else
				reject(`errored: {err}`)
			end
		end)
	end):timeout(timeout, `didn't finish within {timeout}s, so Init stopped waiting for it (it keeps running)`)
end

-- Calls a hook method, reporting its errors instead of breaking the signal that called it
local function safeCall(item: Loaded, methodName: string, method: (...any) -> ...any, ...: any)
	local ok, err = xpcall(method, debug.traceback, item.value, ...)
	if not ok then
		report(`{item.name}:{methodName}() errored: {err}`)
	end
end

local function onStep(callback: (dt: number) -> ())
	if #stepCallbacks == 0 then
		local accumulated = 0
		RunService.Heartbeat:Connect(function(dt: number)
			accumulated += math.min(dt, MAX_FRAME)
			while accumulated >= FIXED_STEP do
				accumulated -= FIXED_STEP
				for _, stepCallback in stepCallbacks do
					stepCallback(FIXED_STEP)
				end
			end
		end)
	end
	table.insert(stepCallbacks, callback)
end

local function connect(item: Loaded, settings: Settings)
	local value = item.value

	local function hook(methodName: string, subscribe: ((...any) -> ()) -> (), profiled: boolean?)
		local method = getMethod(value, methodName)
		if not method then
			return
		end
		local label = settings.DebugLabelFormat:format(item.name, methodName)
		subscribe(function(...)
			if profiled then
				debug.profilebegin(label)
				safeCall(item, methodName, method, ...)
				debug.profileend()
			else
				safeCall(item, methodName, method, ...)
			end
		end)
	end

	local function signal(event: RBXScriptSignal): ((...any) -> ()) -> ()
		return function(callback)
			event:Connect(callback)
		end
	end

	hook(settings.PlayerAdded, function(callback)
		for _, player in Players:GetPlayers() do
			task.spawn(callback, player)
		end
		Players.PlayerAdded:Connect(callback)
	end)
	hook(settings.PlayerRemoving, signal(Players.PlayerRemoving))
	hook(settings.Accumulator, onStep, true)
	hook(settings.Heartbeat, signal(RunService.Heartbeat), true)
	hook(settings.Stepped, signal(RunService.Stepped), true)

	if REALM ~= "Client" then
		return
	end

	local player = Players.LocalPlayer
	hook(settings.RenderStepped, signal(RunService.RenderStepped), true)
	hook(settings.CharacterAdded, function(callback)
		if player.Character then
			task.spawn(callback, player.Character)
		end
		player.CharacterAdded:Connect(callback)
	end)
	hook(settings.CharacterRemoving, signal(player.CharacterRemoving))
	hook(settings.Died, function(callback)
		local function watch(character: Model)
			local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
			if humanoid then
				(humanoid :: Humanoid).Died:Connect(callback)
			end
		end
		if player.Character then
			task.spawn(watch, player.Character)
		end
		player.CharacterAdded:Connect(watch)
	end)
end

--[=[
	Loads and starts every module the entries point at. Call it once per realm: from one Script on
	the server and one LocalScript on the client.

	1. **Load:** requires the modules, entry by entry. Inside an entry, modules with a lower
	   `Priority` attribute go first. Modules with an `Ignore` attribute, modules a Predicate turns
	   down and ModuleScripts that sit inside another ModuleScript are skipped.
	2. **Init:** calls `Init` on each module, one at a time, in load order. If one errors or takes
	   longer than `InitTimeout`, it's reported and that module won't Start.
	3. **Start:** calls `Start` on every module at once (a Start that waits doesn't hold up the
	   others). Each module's hooks (`OnPlayerAdded`, `OnHeartbeat`, ...) connect as soon as its
	   own Start returns.

	The returned promise resolves after every Start has returned (or hit `StartTimeout`), with the
	loaded modules by name, how many loaded, and how long it took in seconds.

	```lua
	Init.start(entries):andThen(function(modules, count, seconds)
		workspace:SetAttribute("ServerStarted", true)
	end)
	```

	@param entries Entries -- what to load, in order
	@param settings { [string]: any }? -- overrides for any of the [settings](https://kashtheking.com/init/docs/guides/settings)
	@return Promise<Modules, number, number>
	@yields false
]=]
function Init.start(entries: Entries, settings: { [string]: any }?): Promise.TypedPromise<Modules, number, number>
	assert(type(entries) == "table", "[Init] Init.start needs a list of entries")
	if started then
		error(`[Init] Init.start was already called on the {REALM}; each realm boots once.`, 2)
	end
	local options = resolveSettings(settings)
	local ordered = orderEntries(entries)
	started = true

	local function verbose(message: string)
		if options.Verbose then
			print(`ℹ️ [Init] {message}`)
		end
	end

	return Promise.new(function(resolve)
		local clock = os.clock()
		if options.DefaultLogEnabled then
			print(`🔲 Initializing {REALM}`)
		end

		-- 1. Load
		local loaded: { Loaded } = {}
		local modules: Modules = {}
		local seen = {}
		for _, entry in ordered do
			for _, module in collect(entry, options, seen) do
				local ok, value = load(module)
				if not ok then
					continue
				end
				if modules[module.Name] ~= nil then
					report(
						`Two loaded modules are named "{module.Name}". Both run, but the modules table only keeps the first; rename {module:GetFullName()}.`
					)
				else
					modules[module.Name] = value
				end
				table.insert(loaded, { name = module.Name, value = value })
				verbose(`Loaded {module:GetFullName()}`)
			end
		end

		-- 2. Init, one module at a time
		local ready: { Loaded } = {}
		for _, item in loaded do
			local promise = call(item, options.InitMethod, options.InitTimeout)
			if promise then
				local ok, err = promise:await()
				if not ok then
					report(`{item.name}:{options.InitMethod}() {err}\n{item.name} won't Start.`)
					continue
				end
				verbose(`{item.name}:{options.InitMethod}() finished`)
			end
			table.insert(ready, item)
		end

		-- 3. Start, every module at once; hooks connect when each Start returns
		local starts = {}
		for _, item in ready do
			local promise = call(item, options.StartMethod, options.StartTimeout) or Promise.resolve()
			table.insert(
				starts,
				promise
					:catch(function(err)
						report(`{item.name}:{options.StartMethod}() {err}`)
					end)
					:andThen(function()
						connect(item, options)
						verbose(`{item.name} started`)
					end)
					:catch(function(err)
						report(`Couldn't connect {item.name}'s methods: {err}`)
					end)
			)
		end
		Promise.all(starts):await()

		local seconds = round(os.clock() - clock)
		if options.DefaultLogEnabled then
			local word = if #loaded == 1 then "module" else "modules"
			print(`✅ Initialized {#loaded} {REALM} {word} in {seconds}s`)
		end
		resolve(modules, #loaded, seconds)
	end)
end

--[=[
	Makes a Predicate that keeps modules whose name matches a
	[string pattern](https://create.roblox.com/docs/luau/strings#string-patterns).

	```lua
	{ Folders = { ServerScriptService.Services }, Predicate = Init.matchesName("Service$") } -- names ending in Service
	```

	@param pattern string
	@return (module: ModuleScript) -> boolean
]=]
function Init.matchesName(pattern: string): (module: ModuleScript) -> boolean
	return function(module: ModuleScript): boolean
		return module.Name:match(pattern) ~= nil
	end
end

return Init

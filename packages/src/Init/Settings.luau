--!strict
-- The default settings. Override any of them with the second argument of Init.start; a key that
-- isn't listed here is an error, so typos are caught:
--
--     Init.start(entries, { Verbose = true, StartTimeout = 30 })
export type Settings = {
	Verbose: boolean,
	DefaultLogEnabled: boolean,
	DebugLabelFormat: string,

	InitTimeout: number,
	StartTimeout: number,
	DefaultPriority: number,

	IgnoreAttribute: string,
	PriorityAttribute: string,

	InitMethod: string,
	StartMethod: string,
	PlayerAdded: string,
	PlayerRemoving: string,
	Accumulator: string,
	Heartbeat: string,
	Stepped: string,
	RenderStepped: string,
	Died: string,
	CharacterAdded: string,
	CharacterRemoving: string,
}

local Settings: Settings = {
	-- Logging
	Verbose = false, -- log every module as it loads, initializes, starts and connects
	DefaultLogEnabled = true, -- log "🔲 Initializing Server" and "✅ Initialized 12 Server modules in 0.05s"
	DebugLabelFormat = "%s - %s", -- MicroProfiler label for per-frame methods (module name, method name)

	-- Loading
	InitTimeout = 3, -- seconds Init waits for a module's Init before reporting it and moving on
	StartTimeout = 15, -- seconds Init waits for a module's Start before reporting it and moving on
	DefaultPriority = 0, -- priority of modules without a Priority attribute (lower loads first)

	-- Attributes you can put on a ModuleScript
	IgnoreAttribute = "Ignore", -- true: Init skips the module
	PriorityAttribute = "Priority", -- a number: load order inside its entry (lower first)

	-- Method names Init looks for on each module. Every one is optional.
	InitMethod = "Init", -- called first, one module at a time, in load order
	StartMethod = "Start", -- called after every Init has finished, all modules at once
	PlayerAdded = "OnPlayerAdded", -- (player) for players already in the game, then every player who joins
	PlayerRemoving = "OnPlayerRemoving", -- (player) when a player leaves
	Accumulator = "Step", -- (dt) at a fixed 60 times a second, however fast the frames run
	Heartbeat = "OnHeartbeat", -- (dt) every RunService.Heartbeat
	Stepped = "OnStepped", -- (time, dt) every RunService.Stepped
	RenderStepped = "OnRenderStepped", -- (dt) client only, every RunService.RenderStepped
	Died = "OnDied", -- () client only, when the local player's Humanoid dies
	CharacterAdded = "OnCharacterAdded", -- (character) client only, the local player's current and new characters
	CharacterRemoving = "OnCharacterRemoving", -- (character) client only, when the local player's character is removed
}

return table.freeze(Settings)

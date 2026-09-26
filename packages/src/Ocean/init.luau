--[[
	Infinite Ocean module. Copyright (c) 2026 KashTheKing. MIT licence (LICENSE): modify and
	distribute freely, keep this notice. Support and feedback: @KashTheKing (Roblox, Discord, YouTube, X).

	Ocean: infinite EditableMesh Gerstner ocean, synced server/client. Just the ocean - no lighting,
	no weather effects. It exposes a weather API so other systems can drive the sea state.

		local Ocean = require(ReplicatedStorage.Ocean)
		Ocean.Init()   -- once on the server and once on each client (OceanServer/OceanClient do this)

	Weather (server only; replicates, and server physics + client visuals stay in step):
		Ocean:CreateWeather("Rough", Ocean.Presets.Ocean["Pirate Seas"])   -- a named set of setting overrides
		Ocean:SetWeather("Storm", 20)                       -- whole ocean, cross-faded over 20 s
		Ocean:CreateZone("Bay", { Position = Vector3.new(0, 0, 2000), Radius = 800, Weather = "Calm" })
		Ocean:SetZoneWeather("Bay", "Storm", 10)
		Ocean:RemoveZone("Bay")

	Queries (either side):
		Ocean:GetHeight(position) -> world Y of the surface above/below that point, right now
		Ocean:GetWeatherAt(position) -> name of the dominant weather there

	Settings are attributes on this ModuleScript (defaults in Ocean.Settings); the server owns them.
	Tags (CollectionService - add them from scripts, the plugin, or the Tag Editor):
		OceanFloat     unanchored BasePart floats via the Buoyancy addon (OceanBuoyancy / OceanDrag tune it)
		OceanObstacle  part/model the sea calms against (OceanShore = ring width, OceanCalmness 0..1)
		OceanDry       part/model with no water inside: submarine interiors, underwater rooms
		OceanTrack     just get water events for it
	Events (Ocean.EnteredWater / ExitedWater / WentUnderWater / WentAboveWater, each (instance)) fire
	for tagged instances and player characters. Queries: GetWaterHeight, GetDepth, IsUnderWater,
	IsAboveWater, IsDry, GetSurfaceNormal, GetWaterState, IsInWater, GetInstancesInWater.
	Zones: tag a part "OceanZone" and any setting set as an attribute on it overrides the module
	inside it (its own sea and buoyancy). The plugin's Zones addon fills those from an Ocean
	preset and handles entering / leaving (lighting). Ocean:GetZoneAt(position) -> name?,
	Ocean:GetZones().
	Characters swim via the plugin's Swimming addon (a separate script), not this module.
]]
--[=[
	@class Ocean

	The module itself: `require(game.ReplicatedStorage.Ocean)`. Everything you need day to day is here:
	weather, zones, water queries, water events and tag helpers. The other classes are the pieces it is
	built from; reach for them only when you need something lower level.

	```lua
	local Ocean = require(game.ReplicatedStorage.Ocean)

	-- server: define a weather and cross-fade the whole sea into it over 20 seconds
	Ocean:CreateWeather("Rough", Ocean.Presets.Ocean["Pirate Seas"])
	Ocean:SetWeather("Rough", 20)

	-- anywhere: where is the surface right now?
	local y = Ocean:GetHeight(boat.Position)
	```

	Settings are attributes on the module (see [Settings]); the server owns them and they replicate.
	The bootstrap scripts the plugin installs call [Ocean.Init] once on the server and once on every
	client, so you never have to.
]=]
--[=[
	@prop Settings Settings
	@within Ocean
	The settings spec and accessors.
]=]
--[=[
	@prop Waves Waves
	@within Ocean
	The wave function: heights, displacement, obstacles.
]=]
--[=[
	@prop Weather Weather
	@within Ocean
	The replicated weather state.
]=]
--[=[
	@prop Presets Presets
	@within Ocean
	Ready-made physics, looks and whole oceans.
]=]
--[=[
	@prop Regions Regions
	@within Ocean
	Dry regions (`OceanDry`).
]=]
--[=[
	@prop Tracker Tracker
	@within Ocean
	Per-instance water state.
]=]
--[=[
	@prop Zones Zones
	@within Ocean
	Tagged `OceanZone` areas.
]=]
--[=[
	@prop Tags { Float: string, Obstacle: string, Dry: string, Track: string }
	@within Ocean
	The current tag names (they follow the `FloatTag`, `ObstacleTag`, `DryTag` and `TrackTag` settings).
]=]
--[=[
	@prop EnteredWater RBXScriptSignal<Instance>
	@within Ocean
	Fires when a tracked instance or character goes from dry to touching the water.
]=]
--[=[
	@prop ExitedWater RBXScriptSignal<Instance>
	@within Ocean
	Fires when a tracked instance or character leaves the water entirely.
]=]
--[=[
	@prop WentUnderWater RBXScriptSignal<Instance>
	@within Ocean
	Fires when a tracked instance or character becomes fully submerged.
]=]
--[=[
	@prop WentAboveWater RBXScriptSignal<Instance>
	@within Ocean
	Fires when a fully submerged instance or character surfaces again.
]=]
local RunService = game:GetService("RunService")

local Ocean = {
	Settings = require(script.Settings),
	Waves = require(script.Waves),
	Weather = require(script.Weather),
	Presets = require(script.Presets),
	Regions = require(script.Regions),
	Tracker = require(script.Tracker),
	Zones = require(script.Zones),
}
-- Ocean.Tags.Float / .Obstacle / .Dry / .Track: the current tag names (FloatTag etc. settings)
Ocean.Tags = setmetatable({}, {
	__index = function(_, key: string)
		return Ocean.Settings.Get(key .. "Tag")
	end,
})
-- Signals: Ocean.EnteredWater:Connect(function(instance) ... end)
Ocean.EnteredWater = Ocean.Tracker.EnteredWater
Ocean.ExitedWater = Ocean.Tracker.ExitedWater
Ocean.WentUnderWater = Ocean.Tracker.WentUnderWater
Ocean.WentAboveWater = Ocean.Tracker.WentAboveWater

local started = false

--[=[
	@within Ocean
	Starts the ocean on this side: reads the settings, compiles the weather, starts obstacle and zone
	tracking, water events and (on a client) the renderer. Safe to call more than once. The installed
	`OceanServer` and `OceanClient` scripts already do this.
]=]
function Ocean.Init()
	if started then
		return
	end
	started = true

	if RunService:IsServer() then
		Ocean.Settings.PublishDefaults()
	end
	Ocean.Waves.Init()
	Ocean.Regions.Init()
	Ocean.Zones.Init()
	Ocean.Tracker.Init()
	if RunService:IsClient() then
		require(script.Renderer).Init()
	end
end

--[=[
	@within Ocean
	@server
	Defines (or redefines) a named weather: a table of setting overrides, keyed by setting name. Only
	settings marked as weather settings count (waves, colours, foam, spray, the underwater tint);
	anything else in the table is ignored, so an entry of [Presets.Ocean] can be passed straight in.

	```lua
	Ocean:CreateWeather("Storm", Ocean.Presets.Ocean["Pirate Seas"])
	Ocean:CreateWeather("Glassy", { WaveHeight = 0.2, FoamOpacity = 0 })
	```
	@param name string -- any name except "Default"
	@param overrides { [string]: any } -- setting name to value
]=]
function Ocean:CreateWeather(name: string, overrides: { [string]: any })
	Ocean.Weather.Create(name, overrides)
end

--[=[
	@within Ocean
	@server
	Cross-fades the whole sea to a weather created with [Ocean:CreateWeather], or back to `"Default"`
	(the module's own attribute values). The fade is a function of server time, so every client and the
	server physics stay in step.
	@param name string
	@param transition number? -- seconds to fade over (default 0)
]=]
function Ocean:SetWeather(name: string, transition: number?)
	Ocean.Weather.Set(name, transition)
end

--[=[
	@within Ocean
	The name of the weather the whole sea is in (or fading toward).
	@return string
]=]
function Ocean:GetWeather(): string
	return Ocean.Weather.State.Global.Current
end

--[=[
	@within Ocean
	@server
	Creates a scripted weather zone: a disc of ocean with its own weather, blended into the surrounding
	sea across `Blend` studs at its rim. For zones built in Studio, tag a part `OceanZone` instead
	(see [Zones]).
	@param name string
	@param zone { Position: Vector3, Radius: number, Blend: number?, Weather: string } -- `Blend` defaults to 35% of the radius
]=]
function Ocean:CreateZone(name: string, zone: { Position: Vector3, Radius: number, Blend: number?, Weather: string })
	Ocean.Weather.CreateZone(name, zone)
end

--[=[
	@within Ocean
	@server
	Cross-fades one scripted zone to another weather.
	@param name string -- the zone
	@param weatherName string
	@param transition number? -- seconds (default 0)
]=]
function Ocean:SetZoneWeather(name: string, weatherName: string, transition: number?)
	Ocean.Weather.SetZone(name, weatherName, transition)
end

--[=[
	@within Ocean
	@server
	Removes a scripted zone; the global weather takes over there.
	@param name string
]=]
function Ocean:RemoveZone(name: string)
	Ocean.Weather.RemoveZone(name)
end

--[=[
	@within Ocean
	World Y of the surface directly above or below the point, right now. Works on both sides and
	accounts for weather, zones, obstacles and `FlatSea`.
	@param position Vector3
	@return number
]=]
function Ocean:GetHeight(position: Vector3): number
	return Ocean.Waves.Height(position.X, position.Z)
end

---------------------------------------------------------------------------------------------
-- Water queries and events. Everything below works on both sides.
---------------------------------------------------------------------------------------------

-- Surface height (world Y) above/below the point right now. Alias of GetHeight.
--[=[
	@within Ocean
	Alias of [Ocean:GetHeight].
	@param position Vector3
	@return number
]=]
function Ocean:GetWaterHeight(position: Vector3): number
	return Ocean.Waves.Height(position.X, position.Z)
end

-- How far under the surface the point is (negative = above). Ignores dry regions.
--[=[
	@within Ocean
	How far below the surface the point is. Negative means above the water. Ignores dry regions.
	@param position Vector3
	@return number
]=]
function Ocean:GetDepth(position: Vector3): number
	return Ocean.Waves.Height(position.X, position.Z) - position.Y
end

--[=[
	@within Ocean
	True when the point is below the surface and not inside a dry region.
	@param position Vector3
	@return boolean
]=]
function Ocean:IsUnderWater(position: Vector3): boolean
	return position.Y < Ocean.Waves.Height(position.X, position.Z) and not Ocean.Regions.IsDry(position)
end

--[=[
	@within Ocean
	The opposite of [Ocean:IsUnderWater].
	@param position Vector3
	@return boolean
]=]
function Ocean:IsAboveWater(position: Vector3): boolean
	return not Ocean:IsUnderWater(position)
end

-- Inside an "OceanDry" region (submarine interior, underwater room)?
--[=[
	@within Ocean
	True inside an `OceanDry` region (a submarine interior, an underwater room).
	@param position Vector3
	@return boolean
]=]
function Ocean:IsDry(position: Vector3): boolean
	return Ocean.Regions.IsDry(position)
end

-- Surface normal at the point (for aligning boats, spray, decals): sampled from the height field.
--[=[
	@within Ocean
	The surface normal at the point, sampled from the height field. Use it to align boats, decals or spray.
	@param position Vector3
	@return Vector3
]=]
function Ocean:GetSurfaceNormal(position: Vector3): Vector3
	local d = 2
	local hx = Ocean.Waves.Height(position.X + d, position.Z) - Ocean.Waves.Height(position.X - d, position.Z)
	local hz = Ocean.Waves.Height(position.X, position.Z + d) - Ocean.Waves.Height(position.X, position.Z - d)
	return Vector3.new(-hx, 2 * d, -hz).Unit
end

-- Touching / Under / Depth for a tracked instance (tagged, or a character), or nil if not tracked.
--[=[
	@within Ocean
	The current water state of a tracked instance (tagged `OceanFloat` or `OceanTrack`, or a player
	character), or nil if it is not tracked.
	@param instance Instance
	@return Tracker.State?
]=]
function Ocean:GetWaterState(instance: Instance)
	return Ocean.Tracker.GetState(instance)
end

--[=[
	@within Ocean
	True when any part of a tracked instance is in the water.
	@param instance Instance
	@return boolean
]=]
function Ocean:IsInWater(instance: Instance): boolean
	local state = Ocean.Tracker.GetState(instance)
	return state ~= nil and state.Touching
end

--[=[
	@within Ocean
	Every tracked instance that is currently in the water.
	@return { Instance }
]=]
function Ocean:GetInstancesInWater(): { Instance }
	return Ocean.Tracker.GetInWater()
end

-- Tag helpers. Plain CollectionService tags underneath, so you can also just :AddTag yourself.
--[=[
	@within Ocean
	Tags a part to float (the plugin's Buoyancy addon does the physics). Plain CollectionService tags
	underneath, so `part:AddTag("OceanFloat")` does the same.
	@param part BasePart
]=]
function Ocean:AddFloat(part: BasePart)
	part:AddTag(Ocean.Tags.Float)
end

--[=[
	@within Ocean
	Removes the float tag.
	@param part BasePart
]=]
function Ocean:RemoveFloat(part: BasePart)
	part:RemoveTag(Ocean.Tags.Float)
end

--[=[
	@within Ocean
	Tags a part or model as an obstacle: the sea calms against it. The `OceanShore` and
	`OceanCalmness` attributes on the instance tune the effect.
	@param instance Instance
]=]
function Ocean:AddObstacle(instance: Instance)
	instance:AddTag(Ocean.Tags.Obstacle)
end

--[=[
	@within Ocean
	Removes the obstacle tag.
	@param instance Instance
]=]
function Ocean:RemoveObstacle(instance: Instance)
	instance:RemoveTag(Ocean.Tags.Obstacle)
end

--[=[
	@within Ocean
	Tags a part or model as a dry region: no water inside its box.
	@param instance Instance
]=]
function Ocean:AddDryRegion(instance: Instance)
	instance:AddTag(Ocean.Tags.Dry)
end

--[=[
	@within Ocean
	Removes the dry-region tag.
	@param instance Instance
]=]
function Ocean:RemoveDryRegion(instance: Instance)
	instance:RemoveTag(Ocean.Tags.Dry)
end

-- Get water events for something without floating it.
--[=[
	@within Ocean
	Gets water events and [Ocean:GetWaterState] for an instance without floating it.
	@param instance Instance
]=]
function Ocean:Track(instance: Instance)
	instance:AddTag(Ocean.Tags.Track)
end

--[=[
	@within Ocean
	Stops tracking an instance.
	@param instance Instance
]=]
function Ocean:Untrack(instance: Instance)
	instance:RemoveTag(Ocean.Tags.Track)
end

-- Zones (tagged "OceanZone"): the one containing the point, all of them, the local player's.
--[=[
	@within Ocean
	The name of the `OceanZone` whose box contains the point, or nil.
	@param position Vector3
	@return string?
]=]
function Ocean:GetZoneAt(position: Vector3): string?
	local zone = Ocean.Zones.At(position)
	return if zone then zone.Name else nil
end

--[=[
	@within Ocean
	The names of every `OceanZone` in the place.
	@return { string }
]=]
function Ocean:GetZones(): { string }
	local names = {}
	for _, zone in Ocean.Zones.List() do
		table.insert(names, zone.Name)
	end
	return names
end

--[=[
	@within Ocean
	The name of the weather with the most influence at a point, zones included.
	@param position Vector3
	@return string
]=]
function Ocean:GetWeatherAt(position: Vector3): string
	local waves = Ocean.Waves
	local count = waves.Gather(waves.ZonesNear(), position.X, position.Z, workspace:GetServerTimeNow())
	local best, bestWeight = Ocean.Weather.DEFAULT, 0
	for i = 1, count do
		if waves.LayerWeights[i] > bestWeight then
			best, bestWeight = waves.LayerSets[i].Name, waves.LayerWeights[i]
		end
	end
	return best
end

-- Studio plugin: render the ocean in Edit mode. `host` is the installed module whose attributes to
-- read (this copy is a throwaway clone); the mesh lives under `into` (the Camera: never saved).
--[=[
	@within Ocean
	@private
	Used by the Studio plugin to render the sea in Edit mode.
]=]
function Ocean.Preview(host: Instance, into: Instance)
	Ocean.Settings.SetHost(host)
	Ocean.Waves.Init()
	Ocean.Regions.Init()
	Ocean.Zones.Init()
	require(script.Renderer).Init(into)
end

--[=[
	@within Ocean
	@private
	Stops an Edit-mode preview.
]=]
function Ocean.StopPreview()
	require(script.Renderer).Stop()
	Ocean.Waves.Stop()
	Ocean.Regions.Stop()
	Ocean.Zones.Stop()
end

return Ocean

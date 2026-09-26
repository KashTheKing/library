--[[
	Weather STATE for the ocean - not a weather controller. Other systems decide what the weather
	is and call Ocean:CreateWeather / :SetWeather / :CreateZone; this just holds the result and
	replicates it (one JSON attribute on the host, so late joiners get it for free).

	A weather type is a set of overrides for the settings marked Weather = true (waves, colours,
	foam, spray). "Default" always exists and is simply the host's attribute values.

	A zone is a disc of ocean with its own weather, blended in over `Blend` studs at its rim.
	Outside every zone the global weather applies. Changes can cross-fade over `transition` seconds;
	the fade is a pure function of server time, so server physics and client visuals agree.
]]
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)

local ATTRIBUTE = "WeatherState"
local DEFAULT = "Default"

--[=[
	@class Weather

	The replicated weather state, behind [Ocean:CreateWeather], [Ocean:SetWeather] and the zone
	methods. It is state, not a controller: your own scripts decide what the weather is. The whole state
	is one JSON attribute on the module, so late joiners get it for free.

	`"Default"` always exists and is simply the module's attribute values.
]=]
--[=[
	@interface Blendable
	@within Weather
	.Current string -- the weather being shown (or faded toward)
	.Previous string? -- the weather being faded from
	.Start number -- server time the fade began
	.Duration number -- seconds
]=]
--[=[
	@interface Zone
	@within Weather
	.X number
	.Z number
	.Radius number
	.Blend number -- studs of rim over which it cross-fades
	.Current string
	.Previous string?
	.Start number
	.Duration number
]=]
--[=[
	@prop State { Weathers: { [string]: { [string]: any } }, Global: Blendable, Zones: { [string]: Zone } }
	@within Weather
	The current state.
]=]
--[=[
	@prop DEFAULT string
	@within Weather
	`"Default"`.
]=]
local Weather = {}
Weather.DEFAULT = DEFAULT
Weather.ATTRIBUTE = ATTRIBUTE

export type Blendable = { Current: string, Previous: string?, Start: number, Duration: number }
export type Zone = Blendable & { X: number, Z: number, Radius: number, Blend: number }

Weather.State = {
	Weathers = {} :: { [string]: { [string]: any } }, -- name -> overrides (Color3 stored as {r, g, b})
	Global = { Current = DEFAULT, Start = 0, Duration = 0 } :: Blendable,
	Zones = {} :: { [string]: Zone },
}

local lastDecoded: string? = nil

local function publish()
	assert(RunService:IsServer() or not RunService:IsRunning(), "Ocean weather can only be changed from the server")
	local encoded = HttpService:JSONEncode(Weather.State)
	lastDecoded = encoded
	Settings.GetHost():SetAttribute(ATTRIBUTE, encoded) -- fires AttributeChanged -> Waves.Refresh on both sides
end

-- Pull the replicated state in. Cheap no-op when unchanged. Every read and mutation below starts
-- with this, so the attribute is the single source of truth even across separate require contexts.
--[=[
	@within Weather
	Pulls the replicated state in if it changed. Every read and write below does this first.
]=]
function Weather.Decode()
	local encoded = Settings.GetHost():GetAttribute(ATTRIBUTE)
	if typeof(encoded) ~= "string" or encoded == lastDecoded then
		return
	end
	local ok, state = pcall(HttpService.JSONDecode, HttpService, encoded)
	if ok and typeof(state) == "table" and state.Global and state.Weathers and state.Zones then
		lastDecoded = encoded
		Weather.State = state
	end
end

--[=[
	@within Weather
	@param name string
	@return boolean
]=]
function Weather.Exists(name: string): boolean
	Weather.Decode()
	return name == DEFAULT or Weather.State.Weathers[name] ~= nil
end

--[=[
	@within Weather
	Every weather name, `"Default"` first, the rest sorted.
	@return { string }
]=]
function Weather.Names(): { string }
	Weather.Decode()
	local names = { DEFAULT }
	for name in Weather.State.Weathers do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- Every Weather = true setting for this weather type: override if it has one, else the attribute.
--[=[
	@within Weather
	Every weather setting for the named weather: its override where it has one, else the module value.
	@param name string
	@return { [string]: any }
]=]
function Weather.Resolve(name: string): { [string]: any }
	local overrides = Weather.State.Weathers[name] or {}
	local resolved = {}
	for _, entry in Settings.List do
		if entry.Weather then
			local value = overrides[entry.Name]
			local forced = Settings.LocalOverride(entry.Name) -- this client's zone look wins everywhere
			if forced ~= nil then
				value = forced
			elseif value == nil then
				value = Settings.Get(entry.Name)
			elseif typeof(entry.Default) == "Color3" then
				value = Color3.new(value[1], value[2], value[3])
			end
			resolved[entry.Name] = value
		end
	end
	return resolved
end

-- 0..1 progress of a cross-fade, smoothed. `now` is workspace:GetServerTimeNow().
--[=[
	@within Weather
	Progress of a cross-fade, 0 to 1, smoothed.
	@param blend Blendable
	@param now number -- `workspace:GetServerTimeNow()`
	@return number
]=]
function Weather.Alpha(blend: Blendable, now: number): number
	if not blend.Previous or blend.Duration <= 0 then
		return 1
	end
	local t = math.clamp((now - blend.Start) / blend.Duration, 0, 1)
	return t * t * (3 - 2 * t)
end

local function retarget(blend: Blendable, name: string, transition: number?)
	assert(Weather.Exists(name), `Unknown ocean weather "{name}" - CreateWeather it first`)
	if blend.Current ~= name then
		blend.Previous = blend.Current
		blend.Current = name
		blend.Start = workspace:GetServerTimeNow()
		blend.Duration = math.max(transition or 0, 0)
	end
end

--[=[
	@within Weather
	@server
	See [Ocean:CreateWeather].
	@param name string
	@param overrides { [string]: any }
]=]
function Weather.Create(name: string, overrides: { [string]: any })
	Weather.Decode()
	assert(typeof(name) == "string" and name ~= DEFAULT, `"{DEFAULT}" is the attribute values; pick another name`)
	local stored = {}
	for key, value in overrides do
		local entry = Settings.Spec[key]
		if not (entry and entry.Weather) then
			continue -- presets may also carry non-weather looks (materials, textures); those are plugin-only
		end
		assert(typeof(value) == typeof(entry.Default), `{key} must be a {typeof(entry.Default)}`)
		if typeof(value) == "Color3" then
			stored[key] = { value.R, value.G, value.B }
		elseif typeof(value) == "number" then
			stored[key] = math.clamp(value, entry.Min :: number, entry.Max :: number)
		else
			stored[key] = value
		end
	end
	Weather.State.Weathers[name] = stored
	publish()
end

--[=[
	@within Weather
	@server
	See [Ocean:SetWeather].
	@param name string
	@param transition number?
]=]
function Weather.Set(name: string, transition: number?)
	Weather.Decode()
	retarget(Weather.State.Global, name, transition)
	publish()
end

--[=[
	@within Weather
	@server
	See [Ocean:CreateZone].
	@param name string
	@param zone { Position: Vector3, Radius: number, Blend: number?, Weather: string }
]=]
function Weather.CreateZone(name: string, zone: { Position: Vector3, Radius: number, Blend: number?, Weather: string })
	Weather.Decode()
	assert(Weather.Exists(zone.Weather), `Unknown ocean weather "{zone.Weather}" - CreateWeather it first`)
	Weather.State.Zones[name] = {
		X = zone.Position.X,
		Z = zone.Position.Z,
		Radius = zone.Radius,
		Blend = math.clamp(zone.Blend or zone.Radius * 0.35, 1, zone.Radius),
		Current = zone.Weather,
		Start = 0,
		Duration = 0,
	}
	publish()
end

--[=[
	@within Weather
	@server
	See [Ocean:SetZoneWeather].
	@param name string
	@param weatherName string
	@param transition number?
]=]
function Weather.SetZone(name: string, weatherName: string, transition: number?)
	Weather.Decode()
	local zone = assert(Weather.State.Zones[name], `Unknown ocean zone "{name}"`)
	retarget(zone, weatherName, transition)
	publish()
end

--[=[
	@within Weather
	@server
	See [Ocean:RemoveZone].
	@param name string
]=]
function Weather.RemoveZone(name: string)
	Weather.Decode()
	Weather.State.Zones[name] = nil
	publish()
end

--[=[
	@within Weather
	@server
	Removes every scripted zone.
]=]
function Weather.ClearZones()
	Weather.Decode()
	table.clear(Weather.State.Zones)
	publish()
end

return Weather

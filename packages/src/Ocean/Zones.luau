--[[
	Zones: tag a BasePart (or Model) "OceanZone" and the sea inside it is its own: any Ocean
	setting set as an attribute on the zone overrides the module's value there. Weather-flagged
	settings (waves, colours, foam, spray) become that zone's ocean weather, blended across the
	zone's rim by the existing per-vertex weather blending; buoyancy settings are blended per
	assembly the same way. The plugin's Zones addon fills those attributes from an Ocean preset
	(the zone's "OceanPreset" attribute) and handles entering / leaving and lighting.

	Zone attributes:
		<any setting name>  override of that Ocean setting inside the zone
		OceanBlend          studs of rim over which the sea cross-fades (default 35% of the radius)

	Refreshed twice a second, so zones can move and attributes can change live.
]]
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)
local Weather = require(script.Parent.Weather)

local WEATHER_PREFIX = "Zone:" -- the zone's ocean weather, so it never clashes with a user weather

--[=[
	@class Zones

	Tag a BasePart or Model `OceanZone` and the sea inside it is its own: any Ocean setting set as an
	attribute on the zone overrides the module's value there. Weather settings (waves, colours, foam,
	spray) become that zone's weather, cross-faded across the rim; buoyancy settings blend per assembly
	the same way. Zones can move and their attributes can change live (they are re-read twice a second).

	Zone attributes:
	- any setting name: override of that setting inside the zone
	- `OceanBlend`: studs of rim over which the sea cross-fades (default 35% of the radius)

	The plugin's Zones addon fills these from an Ocean preset and handles lighting on entering and leaving.
]=]
--[=[
	@interface Zone
	@within Zones
	.Name string
	.Instance Instance
	.CFrame CFrame
	.Half Vector3
	.X number
	.Z number
	.Radius number
	.Blend number
	.Overrides { [string]: any }
]=]
local Zones = {}

export type Zone = {
	Name: string,
	Instance: Instance,
	CFrame: CFrame,
	Half: Vector3,
	X: number,
	Z: number,
	Radius: number,
	Blend: number,
	Overrides: { [string]: any },
}

local list: { Zone } = {}
local published: { [string]: string } = {} -- zone name -> JSON of what the server last published
local connection: RBXScriptConnection? = nil
local timer = 0

local function overridesOf(instance: Instance): { [string]: any }
	local out = {}
	for name, value in instance:GetAttributes() do
		local entry = Settings.Spec[name]
		if entry and typeof(value) == typeof(entry.Default) then
			if typeof(value) == "number" then
				value = math.clamp(value, entry.Min :: number, entry.Max :: number)
			end
			out[name] = value
		end
	end
	return out
end

local function encode(overrides: { [string]: any }, zone: Zone): string
	local flat = {}
	for name, value in overrides do
		flat[name] = if typeof(value) == "Color3" then { value.R, value.G, value.B } else value
	end
	return HttpService:JSONEncode({
		flat,
		math.round(zone.X),
		math.round(zone.Z),
		math.round(zone.Radius),
		math.round(zone.Blend),
	})
end

-- Server: mirror the zone into the replicated weather state (its weather + its disc).
local function publish(zone: Zone)
	local key = encode(zone.Overrides, zone)
	if published[zone.Name] == key then
		return
	end
	published[zone.Name] = key
	Weather.Create(WEATHER_PREFIX .. zone.Name, zone.Overrides)
	Weather.CreateZone(zone.Name, {
		Position = Vector3.new(zone.X, 0, zone.Z),
		Radius = zone.Radius,
		Blend = zone.Blend,
		Weather = WEATHER_PREFIX .. zone.Name,
	})
end

--[=[
	@within Zones
	Re-reads every `OceanZone`. Runs twice a second on its own.
]=]
function Zones.Refresh()
	table.clear(list)
	local seen: { [string]: boolean } = {}
	local authority = RunService:IsServer() or not RunService:IsRunning()
	for _, instance in CollectionService:GetTagged(Settings.Get("ZoneTag")) do
		if not instance:IsDescendantOf(workspace) then
			continue
		end
		local cframe, size
		if instance:IsA("Model") then
			cframe, size = instance:GetBoundingBox()
		elseif instance:IsA("BasePart") then
			cframe, size = instance.CFrame, instance.Size
		else
			continue
		end
		local name = instance.Name
		if seen[name] then
			warn(`[Ocean] two zones named "{name}": rename one`)
			continue
		end
		seen[name] = true
		local half = size / 2
		local right, up, look = cframe.RightVector, cframe.UpVector, cframe.LookVector
		local ex = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z
		local ez = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
		local radius = math.sqrt(ex * ex + ez * ez)
		local blend = instance:GetAttribute("OceanBlend")
		local zone: Zone = {
			Name = name,
			Instance = instance,
			CFrame = cframe,
			Half = half,
			X = cframe.Position.X,
			Z = cframe.Position.Z,
			Radius = radius,
			Blend = math.clamp(if typeof(blend) == "number" then blend else radius * 0.35, 1, radius),
			Overrides = overridesOf(instance),
		}
		table.insert(list, zone)
		if authority then
			publish(zone)
		end
	end
	-- zones that are gone leave the weather state too
	if authority then
		for name in published do
			if not seen[name] then
				published[name] = nil
				Weather.RemoveZone(name)
			end
		end
	end
end

--[=[
	@within Zones
	Every zone.
	@return { Zone }
]=]
function Zones.List(): { Zone }
	return list
end

-- The zone whose box contains the point (the first one, if they overlap), or nil.
--[=[
	@within Zones
	The zone whose box contains the point (the first, if they overlap), or nil.
	@param position Vector3
	@return Zone?
]=]
function Zones.At(position: Vector3): Zone?
	for _, zone in list do
		local l = zone.CFrame:PointToObjectSpace(position)
		if math.abs(l.X) <= zone.Half.X and math.abs(l.Y) <= zone.Half.Y and math.abs(l.Z) <= zone.Half.Z then
			return zone
		end
	end
	return nil
end

-- A numeric setting at (x, z): the module's value, pulled toward each zone's override across its
-- rim with the same fade the sea uses, so physics and visuals agree.
--[=[
	@within Zones
	A numeric setting at `(x, z)`: the module's value pulled toward each zone's override across its rim,
	with the same fade the sea uses.
	@param name string
	@param x number
	@param z number
	@return number
]=]
function Zones.Value(name: string, x: number, z: number): number
	local value = Settings.Get(name)
	for _, zone in list do
		local override = zone.Overrides[name]
		if override ~= nil then
			local dx, dz = x - zone.X, z - zone.Z
			local d = math.sqrt(dx * dx + dz * dz)
			if d < zone.Radius then
				local inner = zone.Radius - zone.Blend
				local t = math.clamp((d - inner) / zone.Blend, 0, 1)
				local weight = 1 - t * t * (3 - 2 * t)
				value += (override - value) * weight
			end
		end
	end
	return value
end

--[=[
	@within Zones
	@private
]=]
function Zones.Init()
	if connection then
		return
	end
	Zones.Refresh()
	connection = RunService.Heartbeat:Connect(function(dt)
		timer += dt
		if timer >= 0.5 then
			timer = 0
			Zones.Refresh()
		end
	end)
end

--[=[
	@within Zones
	@private
]=]
function Zones.Stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

return Zones

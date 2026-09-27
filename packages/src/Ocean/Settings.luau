--[[
	Every tunable is an attribute on the Ocean ModuleScript (the "host"). The server writes them,
	so they replicate; the Studio plugin and the debug menu are both generated from Settings.List.

	Entries marked Weather = true are what a weather type may override (see Weather.luau); the
	attribute values themselves are the "Default" weather.
]]
--[=[
	@class Settings

	Every tunable is an attribute on the Ocean ModuleScript. The server writes them, so they replicate
	to every client; the Studio plugin's panel is generated from [Settings.List]. Change them from a
	server script with [Settings.Set] or simply `Ocean:SetAttribute(name, value)`.

	Settings marked `Weather = true` are the ones a weather can override (see [Ocean:CreateWeather]).
]=]
--[=[
	@interface Entry
	@within Settings
	.Name string -- the attribute name
	.Default number | boolean | Color3 | string
	.Section string -- the panel section it belongs to
	.Min number? -- numbers only
	.Max number? -- numbers only
	.Step number? -- slider step
	.Weather boolean? -- a weather may override it
	.Rebuild boolean? -- changing it rebuilds the surface mesh
	.Options { string }? -- strings with a fixed set of choices
	.Snaps { number }? -- numbers whose slider lands on these values only
	.Hint string? -- what the setting does, as shown in the plugin
]=]
--[=[
	@prop List { Entry }
	@within Settings
	Every setting, in panel order.
]=]
--[=[
	@prop Spec { [string]: Entry }
	@within Settings
	The same entries keyed by name.
]=]
--[=[
	@prop Defaults { [string]: any }
	@within Settings
	Default value per setting name.
]=]
local Settings = {}

Settings.WAVE_COUNT = 6

export type Entry = {
	Name: string,
	Default: number | boolean | Color3 | string,
	Section: string,
	Min: number?,
	Max: number?,
	Step: number?,
	Weather: boolean?,
	Rebuild: boolean?, -- changing it rebuilds the mesh
	Options: { string }?, -- string settings with a fixed set of choices
	Snaps: { number }?, -- number settings whose slider lands on these values only
	Hint: string?,
}

local function num(name, default, min, max, step, section, extra): Entry
	local entry = { Name = name, Default = default, Min = min, Max = max, Step = step, Section = section }
	for key, value in extra or {} do
		entry[key] = value
	end
	return entry
end

Settings.List = {
	-- Physics: everything the surface height itself depends on lives here, not under Visuals
	num("SeaLevel", 0, -500, 500, 1, "General Physics", { Hint = "World Y of the resting surface" }),
	{
		Name = "FlatSea",
		Default = false,
		Section = "General Physics",
		Hint = "No waves at all: the sea is the flat water at SeaLevel, in the water's colour and material, with the underwater tint. Buoyancy, swimming and water events work on that flat surface",
	},
	num("SeafloorHeight", -436, -10000, 10000, 1, "General Physics", {
		Hint = "World Y of the seafloor slab the plugin places (Flat Water and Seafloor). Kept under the deepest wave trough and that much above the fallen-parts height",
	}),
	num("WaveGravity", 60, 5, 2000, 1, "Wave Physics", { Weather = true, Hint = "Wave speed: higher is faster" }),
	num("WaveHeight", 1, 0, 12, 0.05, "Wave Physics", {
		Weather = true,
		Hint = "Size of the whole sea: every wave's height and length times this, so giant waves keep their shape",
	}),
	num(
		"TimeScale",
		1,
		0,
		3,
		0.05,
		"Wave Physics",
		{ Hint = "Overall wave speed: the wave clock runs this many times faster" }
	),
	{
		Name = "UseWind",
		Default = false,
		Section = "Wave Physics",
		Hint = "Waves follow workspace.GlobalWind: the Wave angles become offsets from the wind direction",
	},
	{
		Name = "BuoyancyEnabled",
		Default = true,
		Section = "Buoyancy Physics",
		Hint = 'Floats parts tagged "OceanFloat"',
	},
	num("WaterDensity", 1, 0.1, 5, 0.05, "Buoyancy Physics", {
		Hint = "Density of the water: parts denser than this sink, lighter ones float",
	}),
	num("LinearDrag", 1.5, 0, 10, 0.1, "Buoyancy Physics", {
		Hint = "Resistance to floating parts moving through the water",
	}),
	num("AngularDrag", 2, 0, 10, 0.1, "Buoyancy Physics", { Hint = "Resistance to floating parts turning" }),
	num("MaxLift", 1.3, 1, 6, 0.05, "Buoyancy Physics", {
		Hint = "Cap on total lift, as a multiple of the part's weight",
	}),
	num("BuoyancyFalloffDepth", 40, 1, 500, 1, "Buoyancy Physics", {
		Hint = "Lift fades from full at the surface to DeepBuoyancy this many studs down (submarines)",
	}),
	num(
		"DeepBuoyancy",
		0.7,
		0,
		1,
		0.01,
		"Buoyancy Physics",
		{ Hint = "Lift multiplier once deeper than the falloff depth" }
	),

	{
		Name = "Quality",
		Default = "Regular",
		Options = { "Fast", "Regular", "Realistic" },
		Section = "Performance",
		Rebuild = true,
		Hint = "Fast, Regular or Realistic: how many vertices animate and how often foam and film update",
	},
	{
		Name = "ShallowColor",
		Default = Color3.fromRGB(20, 110, 160),
		Section = "Visuals",
		Weather = true,
		Hint = "Crests",
	},
	{
		Name = "DeepColor",
		Default = Color3.fromRGB(12, 84, 131),
		Section = "Visuals",
		Weather = true,
		Hint = "Troughs",
	},
	{
		Name = "FoamColor",
		Default = Color3.fromRGB(255, 255, 255),
		Section = "Visuals",
		Weather = true,
		Hint = "Colour of the crest foam",
	},
	num("NightBrightness", 0.55, 0, 1, 0.01, "Visuals", { Hint = "Colour multiplier once the sun is down" }),
	-- the underwater tint: a full-screen frame the module owns, shown while the camera is under
	{
		Name = "UnderwaterEnabled",
		Default = true,
		Section = "Visuals",
		Hint = "Tint the view while the camera is under the surface",
	},
	{
		Name = "UnderwaterTint",
		Default = Color3.fromRGB(12, 84, 131),
		Section = "Visuals",
		Weather = true,
		Hint = "Underwater tint colour",
	},
	num("UnderwaterOpacity", 1, 0, 1, 0.01, "Visuals", {
		Weather = true,
		Hint = "How strongly the underwater tint covers the view (0 = none)",
	}),
	num("Reflectance", 0.05, 0, 1, 0.01, "Visuals", { Hint = "How much of the sky the surface mirrors" }),
	num("WaveShading", 1, 0, 2, 0.05, "Visuals", {
		Hint = "How strongly the waves' slopes catch the light: faces toward the sun brighten, the far sides darken (0 = lit like a flat sheet)",
	}),
	{
		Name = "SurfaceDetail",
		Default = "None",
		Options = { "Ripples", "Custom", "None" },
		Section = "Visuals",
		Hint = "Small ripples lit per pixel, finer than the waves: Ripples = the built-in animated ones; Custom = a SurfaceAppearance named WaterSurface you put inside the Ocean module; None = plain WaterMaterial",
	},
	num("RippleStrength", 0.35, 0, 1, 0.01, "Visuals", {
		Hint = "How choppy the Ripples are (their average slope)",
	}),
	num("WaterRoughness", 0.15, 0, 1, 0.01, "Visuals", {
		Hint = "With Ripples: 0 = glassy, sharp sun glints and sky reflection; 1 = matte",
	}),
	{
		Name = "FoamStyle",
		Default = "Animated",
		Options = { "Animated", "Texture", "Solid", "None" },
		Section = "Visuals",
		Rebuild = true,
		Hint = "Crest foam: Animated = the built-in moving rings; Texture = your FoamTexture image; Solid = plain FoamColor; None = no foam layer",
	},
	-- heights below are fractions of the tallest possible crest (sum of wave amplitudes)
	num("FoamStart", 0.45, -1, 1, 0.01, "Visuals", {
		Weather = true,
		Hint = "Crest height (0 to 1 of the tallest crest) where foam begins",
	}),
	num("FoamFull", 0.9, -1, 1, 0.01, "Visuals", {
		Weather = true,
		Hint = "Crest height where the foam is fully opaque",
	}),
	num("FoamOpacity", 0.35, 0, 1, 0.01, "Visuals", { Weather = true, Hint = "Opacity of the crest foam" }),
	num("WebOpacity", 0, 0, 1, 0.01, "Visuals", {
		Weather = true,
		Hint = "Semi-transparent animated foam over the whole near surface, not only the crests (0 = off)",
	}),
	num(
		"SplashRate",
		2,
		0,
		40,
		1,
		"Visuals",
		{ Weather = true, Hint = "Crest spray bursts per second near the camera (drawn by the WaterSplash addon)" }
	),
	num("SplashHeight", 0.4, 0, 1, 0.01, "Visuals", {
		Weather = true,
		Hint = "Crest height (0 to 1 of the tallest crest) a wave must reach to throw spray",
	}),
	num("FilmOpacity", 0.05, 0, 1, 0.01, "Visuals", {
		Weather = true,
		Hint = "Translucent skin on the surface in the water's colour: things crossing it get a clear waterline",
	}),
	{
		Name = "WaterMaterial",
		Default = "SmoothPlastic",
		Section = "Visuals",
		Material = true,
		Hint = "A material name (SmoothPlastic, Foil, Glass, Ice...) or one of the place's MaterialVariants; an unknown name lands on the closest",
	},
	{
		Name = "WaterTexture",
		Default = "",
		Section = "Visuals",
		Hint = "Image asset id tiled over the water (multiplies the colour), or blank for none",
	},
	{
		Name = "FoamTexture",
		Default = "",
		Section = "Visuals",
		Hint = "Image asset id for the crest foam (white with alpha), used when FoamStyle is Texture",
	},

	{
		Name = "StaticWaves",
		Default = false,
		Section = "Performance",
		Hint = "The waves hold still: the wave clock stops, so the surface (and everything floating on it) is built once and left",
	},
	{
		Name = "DynamicLighting",
		Default = true,
		Section = "Performance",
		Hint = "The water darkens with the sun (NightBrightness) as the day passes; off keeps daytime colours",
	},
	{
		Name = "DynamicColors",
		Default = true,
		Section = "Performance",
		Hint = "The crest foam follows the waves every update; off writes it once",
	},
	{
		Name = "Lit",
		Default = true,
		Section = "Performance",
		Hint = "The scene lights the water: shadows and the sun's highlights fall on it. Off draws it in flat colour",
	},
	{
		Name = "Highlights",
		Default = true,
		Section = "Performance",
		Rebuild = true,
		Hint = "The translucent skin layer over the near water: the surface sheen and the waterline on things crossing it",
	},
	num("UpdateRate", 60, 15, 240, 1, "Performance", {
		Snaps = { 15, 24, 30, 45, 60, 72, 90, 120, 144, 165, 240 }, -- the slider lands on these; type anything else
		Hint = "How many times per second the surface mesh is updated",
	}),
	num("CellSize", 8, 2, 32, 1, "Performance", { Rebuild = true, Hint = "Finest quad size (studs)" }),
	num(
		"InnerCells",
		24,
		4,
		44,
		1,
		"Performance",
		{ Rebuild = true, Hint = "Full-detail cells each side (inner + outer at most 49)" }
	),
	num(
		"OuterCells",
		25,
		4,
		45,
		1,
		"Performance",
		{ Rebuild = true, Hint = "Coarser cells past the inner ring, each Growth times larger than the last" }
	),
	num("Growth", 1.2, 1.02, 5, 0.01, "Performance", {
		Rebuild = true,
		Hint = "How much larger each outer cell is than the one before it",
	}),
	num("RenderDistance", 40000, 2000, 100000, 1000, "Performance", {
		Rebuild = true,
		Hint = "How far the sea is drawn from the camera (studs): the flat horizon skirt reaches this far",
	}),
	-- the CollectionService tag names; rename to match tags your game already uses
	{ Name = "FloatTag", Default = "OceanFloat", Section = "Tags", Hint = "Tag: unanchored parts float" },
	{ Name = "ObstacleTag", Default = "OceanObstacle", Section = "Tags", Hint = "Tag: the sea goes idle against it" },
	{ Name = "DryTag", Default = "OceanDry", Section = "Tags", Hint = "Tag: the surface sinks under it" },
	{ Name = "TrackTag", Default = "OceanTrack", Section = "Tags", Hint = "Tag: water events only" },
	{
		Name = "ZoneTag",
		Default = "OceanZone",
		Section = "Tags",
		Hint = "Tag: an area with its own sea, physics and lighting",
	},
}

-- angle (deg), wavelength (studs), steepness. Keep the steepness sum well under 1 or crests pinch
-- into loops, and keep wavelengths >= 6 x CellSize or the mesh (not the physics) smooths them away.
local waveDefaults = {
	{ 15, 320, 0.1 }, -- long swell
	{ -30, 190, 0.12 },
	{ 50, 120, 0.15 }, -- peaky mid-size chop does most of the "rough sea" look
	{ -65, 80, 0.15 },
	{ 100, 56, 0.12 },
	{ -10, 48, 0.1 },
}
for i, wave in waveDefaults do
	table.insert(
		Settings.List,
		num(`Wave{i}Angle`, wave[1], -180, 180, 1, `Wave{i}`, {
			Weather = true,
			Hint = "Direction this wave travels (degrees)",
		})
	)
	table.insert(
		Settings.List,
		num(`Wave{i}Length`, wave[2], 10, 1000, 1, `Wave{i}`, {
			Weather = true,
			Hint = "Distance between crests (studs)",
		})
	)
	table.insert(
		Settings.List,
		num(`Wave{i}Steepness`, wave[3], 0, 0.5, 0.01, `Wave{i}`, {
			Weather = true,
			Hint = "How peaked this wave is (0 = flat)",
		})
	)
end

Settings.Defaults = {}
Settings.Spec = {} :: { [string]: Entry }
for _, entry in Settings.List do
	Settings.Defaults[entry.Name] = entry.Default
	Settings.Spec[entry.Name] = entry
end

local host: Instance = script.Parent

-- The plugin's edit-mode preview runs a clone of the module but reads the installed one's attributes.
--[=[
	@within Settings
	@private
]=]
function Settings.SetHost(instance: Instance)
	host = instance
end

--[=[
	@within Settings
	The Instance whose attributes hold the settings (the Ocean ModuleScript).
	@return Instance
]=]
function Settings.GetHost(): Instance
	return host
end

-- Client-local overrides: values this client uses instead of the host's, for everything that
-- reads Settings.Get (the Zones addon sets the zone's look here for a player inside it, so the
-- whole sea takes that look for them). Never replicated, never written to the host.
local overrides: { [string]: any } = {}
local changed = Instance.new("BindableEvent")

--[=[
	@within Settings
	@client
	A client-local override set with [Settings.SetLocalOverride], or nil.
	@param name string
	@return any
]=]
function Settings.LocalOverride(name: string): any
	return overrides[name]
end

--[=[
	@within Settings
	@client
	Makes this client use `value` instead of the replicated setting, for everything that reads
	[Settings.Get]. Never replicated and never written to the module. The Zones addon uses it to give a
	player inside a zone that zone's look everywhere they look. Pass nil to clear.
	@param name string
	@param value any
]=]
function Settings.SetLocalOverride(name: string, value: any)
	if overrides[name] == value then
		return
	end
	overrides[name] = value
	changed:Fire(name)
end

--[=[
	@within Settings
	The effective value of a setting on this side: the local override if any, else the attribute,
	else the default.
	@param name string
	@return any
]=]
function Settings.Get(name: string): any
	local value = overrides[name]
	if value == nil then
		value = host:GetAttribute(name)
	end
	if value == nil then
		return Settings.Defaults[name]
	end
	return value
end

-- Clamps/validates against the spec; returns the value stored, or nil if rejected.
--[=[
	@within Settings
	@server
	Validates and clamps the value against the spec and writes the attribute. Returns the value stored,
	or nil if it was rejected (unknown name, wrong type, or a string outside the entry's Options).
	@param name string
	@param value any
	@return any
]=]
function Settings.Set(name: string, value: any): any
	local entry = Settings.Spec[name]
	if not entry or typeof(value) ~= typeof(entry.Default) or value ~= value then
		return nil
	end
	if typeof(value) == "number" then
		value = math.clamp(value, entry.Min :: number, entry.Max :: number)
	elseif entry.Options and not table.find(entry.Options, value) then
		return nil
	end
	host:SetAttribute(name, value)
	return value
end

export type Connection = { Disconnect: (self: Connection) -> () }

-- Fires for host attribute changes and for local overrides alike.
--[=[
	@within Settings
	Calls `fn(name)` whenever a setting changes on this side, whether by attribute or local override.
	@param fn (name: string) -> ()
	@return Connection -- call `:Disconnect()` to stop
]=]
function Settings.OnChanged(fn: (name: string) -> ()): Connection
	local a = host.AttributeChanged:Connect(fn)
	local b = changed.Event:Connect(fn)
	return {
		Disconnect = function(_self)
			a:Disconnect()
			b:Disconnect()
		end,
	}
end

-- Server: make every setting a real attribute so it shows in Properties and replicates.
--[=[
	@within Settings
	@server
	Writes every default that is not yet an attribute, so all settings show in Properties and replicate.
	[Ocean.Init] does this.
]=]
function Settings.PublishDefaults()
	for name, default in Settings.Defaults do
		if host:GetAttribute(name) == nil then
			host:SetAttribute(name, default)
		end
	end
end

--[=[
	@within Settings
	@server
	Sets every setting back to its default.
]=]
function Settings.Reset()
	for name, default in Settings.Defaults do
		host:SetAttribute(name, default)
	end
end

return Settings

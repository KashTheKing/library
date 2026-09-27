-- Ready-made overrides, plain data. Three kinds:
--   Presets.Physics  - waves and buoyancy: Calm (the module defaults), Rough, Huge, Tsunami, Still
--   Presets.Visual   - the look: Classic (the module defaults, like Roblox water), Cartoony, Stylized, Realistic
--   Presets.Ocean    - a whole sea = one physics + one look: Island, Pirate Seas, Oil Rig, Great Flood, Blank
-- Each carries only its own keys and applies on top of whatever is set. The plugin lists them by
-- kind; weathers take an Ocean preset: Ocean:CreateWeather("Pirate Seas", Ocean.Presets.Ocean["Pirate Seas"]).
-- Weather ignores non-weather keys (materials, textures, physics).
--[=[
	@class Presets

	Ready-made setting tables, plain data. Each carries only its own keys and applies on top of whatever
	is already set.

	- [Presets.Physics]: waves and buoyancy. `Calm` (the defaults), `Rough`, `Huge`, `Tsunami`, `Still`.
	- [Presets.Visual]: the look. `Classic` (the defaults, like Roblox water), `Cartoony`, `Stylized`, `Realistic`.
	- [Presets.Ocean]: a whole sea, one physics plus one look. `Island`, `Pirate Seas`, `Oil Rig`, `Great Flood`, `Blank`.

	Any of them can be a weather: `Ocean:CreateWeather("Storm", Ocean.Presets.Ocean["Pirate Seas"])`.
	Weather ignores the non-weather keys (materials, textures, physics).
]=]
--[=[
	@prop Physics { [string]: { [string]: any } }
	@within Presets
	Wave and buoyancy presets by name.
]=]
--[=[
	@prop Visual { [string]: { [string]: any } }
	@within Presets
	Look presets by name.
]=]
--[=[
	@prop Ocean { [string]: { [string]: any } }
	@within Presets
	Whole-sea presets by name.
]=]
--[=[
	@prop Lighting { [string]: any }
	@within Presets
	Per Ocean preset, the Lighting properties and Atmosphere/effects the plugin applies with it.
]=]
--[=[
	@prop Aliases { [string]: string }
	@within Presets
	Older preset names mapped to current ones (`Storm`, `Deep Sea`, `Flat`, `Calm`).
]=]
local Presets = {}

local function waves(list: { { number } }, into: { [string]: any }): { [string]: any }
	for i, wave in list do
		into[`Wave{i}Angle`], into[`Wave{i}Length`], into[`Wave{i}Steepness`] = wave[1], wave[2], wave[3]
	end
	return into
end

local function merge(...: { [string]: any }): { [string]: any }
	local into = {}
	for _, layer in { ... } do
		for key, value in layer do
			into[key] = value
		end
	end
	return into
end

-- An Ocean preset by name, aliases included.
--[=[
	@within Presets
	An Ocean preset by name, aliases included.
	@param name string
	@return { [string]: any }?
]=]
function Presets.Find(name: string): { [string]: any }?
	return Presets.Ocean[name] or Presets.Ocean[Presets.Aliases[name]]
end

Presets.Physics = {
	-- the module defaults, spelled out so applying it always lands on them
	Calm = waves({
		{ 15, 320, 0.1 },
		{ -30, 190, 0.12 },
		{ 50, 120, 0.15 },
		{ -65, 80, 0.15 },
		{ 100, 56, 0.12 },
		{ -10, 48, 0.1 },
	}, { WaveGravity = 60, WaveHeight = 1, TimeScale = 1 }),
	Rough = waves({
		{ 25, 420, 0.14 },
		{ -20, 260, 0.16 },
		{ 60, 160, 0.16 },
		{ -55, 100, 0.14 },
		{ 110, 64, 0.11 },
		{ 5, 48, 0.09 },
	}, { WaveGravity = 90 }),
	Huge = waves({
		{ 10, 900, 0.14 }, -- long, slow open-ocean swell
		{ -25, 600, 0.14 },
		{ 40, 320, 0.12 },
		{ -60, 160, 0.1 },
		{ 95, 80, 0.06 },
		{ -5, 48, 0.04 },
	}, { WaveGravity = 45 }),
	Tsunami = waves({
		{ 0, 1000, 0.45 }, -- one wall of water
		{ 6, 1000, 0.25 },
		{ 30, 300, 0.08 },
		{ -40, 140, 0.06 },
		{ 100, 70, 0.04 },
		{ -10, 48, 0.03 },
	}, { WaveGravity = 25 }),
	Still = waves({
		{ 15, 320, 0 },
		{ -30, 190, 0 },
		{ 50, 120, 0 },
		{ -65, 80, 0 },
		{ 100, 56, 0 },
		{ -10, 48, 0 },
	}, {}),
}

Presets.Visual = {
	-- like Roblox's own water: its blue, a touch of reflection, faint crest foam
	Classic = {
		ShallowColor = Color3.fromRGB(20, 110, 160),
		DeepColor = Color3.fromRGB(12, 84, 131),
		FoamColor = Color3.fromRGB(255, 255, 255),
		UnderwaterTint = Color3.fromRGB(12, 84, 131),
		UnderwaterOpacity = 1,
		Reflectance = 0.05,
		FoamStyle = "Animated",
		FoamStart = 0.45,
		FoamFull = 0.9,
		FoamOpacity = 0.35,
		FilmOpacity = 0.05,
		SplashRate = 2,
		WaterMaterial = "SmoothPlastic",
		WaterTexture = "",
		FoamTexture = "",
		WaveShading = 1,
		SurfaceDetail = "None",
		RippleStrength = 0.35,
		WaterRoughness = 0.15,
	},
	-- a flat cartoon water build: a matte Slate slab in sky blue under a deeper-blue film with a
	-- faint tiled pattern
	Cartoony = {
		ShallowColor = Color3.fromRGB(4, 175, 236),
		DeepColor = Color3.fromRGB(9, 137, 207),
		FoamColor = Color3.fromRGB(255, 255, 255),
		UnderwaterTint = Color3.fromRGB(9, 137, 207),
		UnderwaterOpacity = 1,
		Reflectance = 0,
		FoamStyle = "None",
		FilmOpacity = 0.25,
		SplashRate = 8,
		WaterMaterial = "Slate",
		WaterTexture = "rbxassetid://6126332496",
		FoamTexture = "",
		WaveShading = 0, -- flat cartoon colour: the waves read by their outline and the film
		SurfaceDetail = "None",
	},
	-- bright flat bands with solid white foam
	Stylized = {
		ShallowColor = Color3.fromRGB(40, 190, 220),
		DeepColor = Color3.fromRGB(20, 120, 190),
		FoamColor = Color3.fromRGB(255, 255, 255),
		UnderwaterTint = Color3.fromRGB(20, 120, 190),
		UnderwaterOpacity = 1,
		Reflectance = 0,
		FoamStyle = "Solid",
		FoamStart = 0.55,
		FoamFull = 0.85,
		FoamOpacity = 1,
		FilmOpacity = 0.2,
		SplashRate = 6,
		WaterMaterial = "Slate",
		WaterTexture = "",
		FoamTexture = "",
		WaveShading = 0, -- flat bands
		SurfaceDetail = "None",
	},
	-- lit per pixel: shaded waves, animated ripples on a glossy surface for the sun glints and the
	-- sky reflection (a low roughness does that, not Reflectance, which mirrors the sky evenly)
	Realistic = {
		ShallowColor = Color3.fromRGB(38, 118, 148),
		DeepColor = Color3.fromRGB(10, 52, 92),
		FoamColor = Color3.fromRGB(236, 244, 246),
		UnderwaterTint = Color3.fromRGB(10, 52, 92),
		UnderwaterOpacity = 1,
		Reflectance = 0.1,
		FoamStyle = "Animated",
		FoamStart = 0.3,
		FoamFull = 0.7,
		FoamOpacity = 0.8,
		FilmOpacity = 0.03,
		SplashRate = 4,
		WaterMaterial = "SmoothPlastic",
		WaterTexture = "",
		FoamTexture = "",
		WaveShading = 1,
		SurfaceDetail = "Ripples",
		RippleStrength = 0.4,
		WaterRoughness = 0.1,
	},
}

-- alias names that resolve to a current preset (weather lists and zones may refer to them)
Presets.Aliases = { Storm = "Pirate Seas", ["Deep Sea"] = "Oil Rig", Flat = "Blank", Calm = "Island" }

Presets.Ocean = {
	-- the default: a calm sea around an island or landmass
	-- every Ocean preset states its rendering too, so switching between them never leaves a
	-- previous preset's Quality or RenderDistance behind
	Island = merge(Presets.Physics.Calm, Presets.Visual.Classic, {
		Quality = "Regular",
		RenderDistance = 40000,
		Lit = true,
		Highlights = true,
		DynamicLighting = true,
		DynamicColors = true,
	}),
	["Pirate Seas"] = merge(Presets.Physics.Rough, Presets.Visual.Stylized, {
		Quality = "Regular",
		RenderDistance = 40000,
		Lit = true,
		Highlights = true,
		DynamicLighting = true,
		DynamicColors = true,
	}),
	["Oil Rig"] = merge(Presets.Physics.Huge, Presets.Visual.Realistic, {
		Quality = "Realistic",
		RenderDistance = 60000,
		Lit = true,
		Highlights = true,
		DynamicLighting = true,
		DynamicColors = true,
	}),
	-- over the top on purpose: the whole sea rendered, at full quality, lit, foaming, every scale cue on
	["Great Flood"] = merge(Presets.Physics.Tsunami, Presets.Visual.Realistic, {
		FoamStyle = "Animated",
		FoamStart = 0.1,
		FoamFull = 0.45,
		FoamOpacity = 1,
		WebOpacity = 0.08,
		FilmOpacity = 0.1,
		Reflectance = 0.45,
		SplashRate = 24,
		SplashHeight = 0.2,
		Quality = "Realistic",
		RenderDistance = 100000,
		Lit = true,
		Highlights = true,
		DynamicLighting = true,
		DynamicColors = true,
	}),
	-- still water and the plainest look, to build your own from
	Blank = merge(Presets.Physics.Still, Presets.Visual.Classic, {
		FoamStyle = "None",
		FilmOpacity = 0,
		SplashRate = 0,
		Reflectance = 0,
		Quality = "Fast",
		RenderDistance = 20000,
		Lit = true,
		Highlights = false,
		DynamicLighting = false,
		DynamicColors = false,
	}),
}

-- Lighting for each Ocean preset, in the LightingSnapshot shape ({ Lighting = props, Children =
-- { { ClassName, Name, Props } } }; colours as { R, G, B } in 0..1). Loaded by the plugin when an
-- Ocean preset is applied (and copied onto zones). Load never deletes what it doesn't mention.
local function rgb(r: number, g: number, b: number)
	return { R = r / 255, G = g / 255, B = b / 255 }
end

Presets.Lighting = {
	Island = {
		Lighting = {
			Brightness = 2.5,
			ClockTime = 13.5,
			GlobalShadows = true,
			ShadowSoftness = 0.3,
			ExposureCompensation = 0,
			Ambient = rgb(90, 100, 110),
			OutdoorAmbient = rgb(140, 150, 160),
			FogColor = rgb(190, 205, 220),
			FogStart = 0,
			FogEnd = 100000,
		},
		Children = {
			{
				ClassName = "Atmosphere",
				Name = "Atmosphere",
				Props = {
					Density = 0.28,
					Offset = 0.2,
					Haze = 1,
					Glare = 0.3,
					Color = rgb(199, 199, 199),
					Decay = rgb(106, 112, 125),
				},
			},
		},
	},
	["Pirate Seas"] = {
		Lighting = {
			Brightness = 1.6,
			ClockTime = 17.4,
			GlobalShadows = true,
			ShadowSoftness = 0.5,
			ExposureCompensation = -0.2,
			Ambient = rgb(60, 62, 70),
			OutdoorAmbient = rgb(95, 100, 110),
			FogColor = rgb(120, 130, 140),
			FogStart = 0,
			FogEnd = 30000,
		},
		Children = {
			{
				ClassName = "Atmosphere",
				Name = "Atmosphere",
				Props = {
					Density = 0.45,
					Offset = 0.5,
					Haze = 3,
					Glare = 0.2,
					Color = rgb(150, 150, 160),
					Decay = rgb(70, 75, 90),
				},
			},
		},
	},
	["Oil Rig"] = {
		Lighting = {
			Brightness = 1.2,
			ClockTime = 9,
			GlobalShadows = true,
			ShadowSoftness = 0.6,
			ExposureCompensation = -0.3,
			Ambient = rgb(70, 75, 80),
			OutdoorAmbient = rgb(110, 115, 120),
			FogColor = rgb(140, 145, 150),
			FogStart = 0,
			FogEnd = 40000,
		},
		Children = {
			{
				ClassName = "Atmosphere",
				Name = "Atmosphere",
				Props = {
					Density = 0.4,
					Offset = 0.35,
					Haze = 2.5,
					Glare = 0,
					Color = rgb(160, 165, 170),
					Decay = rgb(90, 95, 100),
				},
			},
		},
	},
	-- long, hard shadows across the walls of water; haze for distance; bloom on the crests
	["Great Flood"] = {
		Lighting = {
			Brightness = 3.5,
			ClockTime = 16.8,
			GeographicLatitude = 30,
			GlobalShadows = true,
			ShadowSoftness = 0.1,
			ExposureCompensation = 0.25,
			EnvironmentSpecularScale = 1,
			EnvironmentDiffuseScale = 0.6,
			Ambient = rgb(50, 55, 65),
			OutdoorAmbient = rgb(100, 108, 120),
			FogColor = rgb(150, 160, 175),
			FogStart = 0,
			FogEnd = 90000,
		},
		Children = {
			{
				ClassName = "Atmosphere",
				Name = "Atmosphere",
				Props = {
					Density = 0.36,
					Offset = 0.4,
					Haze = 2.2,
					Glare = 0.5,
					Color = rgb(170, 180, 195),
					Decay = rgb(95, 105, 125),
				},
			},
			{
				ClassName = "SunRaysEffect",
				Name = "SunRays",
				Props = { Enabled = true, Intensity = 0.18, Spread = 0.7 },
			},
			{
				ClassName = "BloomEffect",
				Name = "Bloom",
				Props = { Enabled = true, Intensity = 0.6, Size = 24, Threshold = 1.4 },
			},
		},
	},
	-- a clean noon: nothing left over from another preset (no long shadows, no bloom, no rays)
	Blank = {
		Lighting = {
			Brightness = 2,
			ClockTime = 14,
			GlobalShadows = true,
			ShadowSoftness = 0.5,
			ExposureCompensation = 0,
			EnvironmentDiffuseScale = 0,
			EnvironmentSpecularScale = 0,
			Ambient = rgb(70, 70, 70),
			OutdoorAmbient = rgb(128, 128, 128),
			FogColor = rgb(192, 192, 192),
			FogStart = 0,
			FogEnd = 100000,
		},
		Children = {
			{
				ClassName = "Atmosphere",
				Name = "Atmosphere",
				Props = {
					Density = 0.3,
					Offset = 0.25,
					Haze = 0,
					Glare = 0,
					Color = rgb(199, 199, 199),
					Decay = rgb(106, 112, 125),
				},
			},
			{ ClassName = "SunRaysEffect", Name = "SunRays", Props = { Enabled = false } },
			{ ClassName = "BloomEffect", Name = "Bloom", Props = { Enabled = false } },
		},
	},
}

return Presets

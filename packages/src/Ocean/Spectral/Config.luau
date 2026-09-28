--[[
	The FFT sea's simulation settings, shared by the main thread (heights for physics) and every worker
	Actor (the waves it draws): a wave field is a pure function of these numbers and the synced clock, so
	they all compute the same sea. `values` is plain data:
	SeaLevel, WaveHeight, WindSpeed, WindAngle, Chop, Foam.

	(Part of the FFT sea, see Spectral.)
]]
local Simulation = require(script.Parent.Simulation)

local Config = {}

local function cascades(chop: number, foam: number)
	return {
		{
			PatchSize = 620,
			Resolution = 64,
			MinWavelength = 34,
			MaxWavelength = math.huge,
			Amplitude = 1,
			Choppiness = chop,
			FoamCoverage = 0.22 * foam,
			Foam = 1,
		},
		{
			PatchSize = 110,
			Resolution = 64,
			MinWavelength = 3.6,
			MaxWavelength = 34,
			Amplitude = 2,
			Choppiness = chop * 0.85,
			FoamCoverage = 0.07 * foam,
			Foam = 0.8,
			VertexFoam = 0.35, -- the rest of this cascade's foam would need a per-pixel texture
		},
	}
end

-- A simulation for the values.
function Config.simulation(values: any): (any, any)
	local config = {
		SeaLevel = values.SeaLevel,
		Seed = 1790,
		WaveHeight = values.WaveHeight,
		WindSpeed = values.WindSpeed,
		WindDirection = values.WindAngle,
		DirectionalSpread = 3,
		WindAlignment = 0.85,
		SmallWaveCutoff = 0.5,
		Gravity = 35,
		Cascades = cascades(values.Chop, values.Foam),
		FoamSharpness = 2.5,
		FoamDecay = 3.5,
		Chop = values.Chop,
		Foam = values.Foam,
	}
	return config, Simulation.new(config)
end

--[[
	Brings a simulation up to the values, rebuilding only what changed. Returns true when the spectrum
	was regenerated (the wave height or the wind changed), which moves every vertex.
]]
function Config.update(config: any, simulation: any, values: any): boolean
	config.SeaLevel = values.SeaLevel
	local rebuilt = false
	if
		config.WaveHeight ~= values.WaveHeight
		or config.WindSpeed ~= values.WindSpeed
		or config.WindDirection ~= values.WindAngle
	then
		config.WaveHeight, config.WindSpeed, config.WindDirection =
			values.WaveHeight, values.WindSpeed, values.WindAngle
		simulation:Rebuild()
		rebuilt = true
	end
	if config.Chop ~= values.Chop or config.Foam ~= values.Foam then
		config.Chop, config.Foam = values.Chop, values.Foam
		local fresh = cascades(values.Chop, values.Foam)
		for i, cascade in config.Cascades do
			cascade.Choppiness, cascade.FoamCoverage = fresh[i].Choppiness, fresh[i].FoamCoverage
		end
		simulation:CalibrateFoam()
	end
	return rebuilt
end

return Config

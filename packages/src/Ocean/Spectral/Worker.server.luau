-- Draws a share of the FFT sea in parallel (see Clipmap and Spectral). The module clones this script
-- into each of its worker Actors; this copy, next to the module, does nothing.
--
-- Each worker keeps its own copy of the wave simulation (a pure function of the synced clock, so every
-- copy is the same sea) and of the masks, and every frame runs the maths for its share of the tiles in
-- parallel: the FFT, the waves at every vertex, colours, UVs. Only the mesh writes are serial.
local actor = script:GetActor()
if not actor then
	return
end
local RunService = game:GetService("RunService")

local Config: any, Masks: any, Clipmap: any
local clipmap: any = nil
local simulation: any = nil
local simConfig: any = nil
local masks: any = nil
local published: SharedTable? = nil
local lastFrame = -1
local seaVersion = -1
local lastClock = os.clock()
local steps, stepMs, writeMs = 0, 0, 0

local frameValues: { [string]: any } = {}
local seaValues: { [string]: any } = {}

actor:BindToMessage(
	"Load",
	function(spectral: ModuleScript, frame: SharedTable, state: any, sea: any, sources: any, records: any)
		Config = require(spectral:FindFirstChild("Config") :: ModuleScript)
		Masks = require(spectral:FindFirstChild("Masks") :: ModuleScript)
		Clipmap = require(spectral:FindFirstChild("Clipmap") :: ModuleScript)
		masks = Masks.new(sources)
		simConfig, simulation = Config.simulation(sea)
		seaVersion = sea.SeaVersion
		clipmap = Clipmap.forShare(state, simulation, masks, records)
		published = frame
		lastFrame = -1
	end
)

-- the parts that foam where they cross the water (the Contact scan's choice) changed
actor:BindToMessage("Auto", function(parts: { Instance }, falloff: number, strength: number)
	if masks then
		masks:SetAuto(parts, falloff, strength)
	end
end)

-- the water's colours changed: the palette is rebuilt from the config
actor:BindToMessage("Look", function(deep: Color3, crest: Color3, foam: Color3)
	if clipmap then
		clipmap.config.DeepColor, clipmap.config.CrestColor, clipmap.config.FoamColor = deep, crest, foam
		clipmap:RebuildPalette()
	end
end)

local FRAME_KEYS = {
	"CamX",
	"CamY",
	"CamZ",
	"LookX",
	"LookY",
	"LookZ",
	"RightX",
	"RightY",
	"RightZ",
	"UpX",
	"UpY",
	"UpZ",
	"TanY",
	"ViewX",
	"ViewY",
	"Night",
	"Textured",
	"LOD",
	"Flow",
	"FlowAngle",
	"FlowTime",
	"Transparent",
}

RunService.PreRender:ConnectParallel(function()
	local frame = published
	if not (clipmap and frame) or frame.Frame == lastFrame then
		return
	end
	lastFrame = frame.Frame
	local started = os.clock()
	local dt = math.clamp(started - lastClock, 0, 0.25)
	lastClock = started

	if frame.SeaVersion ~= seaVersion then
		seaVersion = frame.SeaVersion
		seaValues.SeaLevel, seaValues.WaveHeight, seaValues.WindSpeed =
			frame.SeaLevel, frame.WaveHeight, frame.WindSpeed
		seaValues.WindAngle, seaValues.Chop, seaValues.Foam = frame.WindAngle, frame.Chop, frame.Foam
		clipmap.config.WaveHeight, clipmap.config.SeaLevel = frame.WaveHeight, frame.SeaLevel
		if Config.update(simConfig, simulation, seaValues) then
			clipmap:InvalidatePlacement()
		end
	end
	simulation:Step(frame.SimTime, dt)
	masks:Update()

	for _, key in FRAME_KEYS do
		frameValues[key] = frame[key]
	end
	clipmap:Configure(frameValues)
	local list = clipmap:UpdateTiles(frameValues, 1, 1)
	local stepped = os.clock()
	task.synchronize()
	local synced = os.clock()
	clipmap:WriteTiles(list)

	-- what this share costs, for the stats: in parallel, and on the main thread
	steps += 1
	stepMs += stepped - started
	writeMs += os.clock() - synced
	if steps >= 30 then
		actor:SetAttribute("StepMs", stepMs / steps * 1000)
		actor:SetAttribute("WriteMs", writeMs / steps * 1000)
		steps, stepMs, writeMs = 0, 0, 0
	end
end)

actor:SetAttribute("Ready", true)

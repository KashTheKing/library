--[[
	The FFT sea: WaveMode = "FFT". An alternative to the Gerstner sea (Waves, Draw, Renderer), built on
	the same idea as a Tessendorf ocean: a spectrum of waves advanced in time and transformed back to
	height and horizontal displacement by an FFT (Simulation, Spectrum, Transform), so crests sharpen,
	hook over and break, and foam spawns where the surface folds. It is drawn as a geometry clipmap of
	EditableMesh tiles with 2 stud cells near the camera and doubling out to the horizon (Clipmap).

	The FFT modules (Transform, Spectrum, Simulation, Masks, Clipmap) are adapted from an FFT ocean made
	by a friend of the author (his OceanDemo place). Get his permission before this ships to anyone else.

	This module is the glue:
	  - the simulation runs on both sides from the synced server clock, so heights (buoyancy, swimming,
	    water events) match what every client draws; Waves.Height / Waves.Displace call in here when the
	    mode is on;
	  - on a client the Renderer asks it to draw the clipmap (StartRender) instead of the Gerstner mesh;
	  - dry regions cut the water (Cutout), obstacles calm it (see Masks).

	In a running game the drawing runs in parallel: WORKERS Actors (Worker.server.luau) each keep their
	own copy of the simulation (the same sea, since it is a pure function of the clock) and update a share
	of the tiles, so the FFT and every vertex's waves, colour and UV are computed off the main thread.
	What cannot go parallel stays serial: an EditableMesh only takes writes from a serial phase (each
	Actor makes its own, after its maths) and heights for physics are asked for synchronously, so the main
	thread keeps a simulation of its own, stepped 30 times a second on a client (20 on the server).
	Without Actors (the plugin's Edit-mode preview) the main thread does it all.
]]
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Clipmap = require(script.Clipmap)
local Config = require(script.Config)
local Masks = require(script.Masks)
local Settings = require(script.Parent.Settings)

local Sea = {}

local TIME_ORIGIN = 1.7e9 -- any fixed origin works as long as every machine uses the same one
local TILE_SIZE = 24 -- studs per texture repeat of the ripples
local SERVER_RATE = 20 -- steps per second of the physics simulation on the server
local CLIENT_RATE = 30 -- ... and on a client that has workers drawing (without them it steps every frame)
local WORKERS = 4 -- Actors drawing the clipmap in parallel, when the game is running on a client
local RENDER_NAME = "OceanSpectral"

local QUALITY = {
	Fast = { GridCells = 32, BaseCellSize = 4, LevelCount = 6 },
	Regular = { GridCells = 32, BaseCellSize = 2, LevelCount = 8 },
	Realistic = { GridCells = 40, BaseCellSize = 2, LevelCount = 8 },
}
-- Coarser clipmaps, best first: tried in order when a device cannot fit the clipmap in its EditableMesh
-- budget, and one per rung as the renderer's adaptive quality lowers the detail (rung 1 is FALLBACKS[1]).
local FALLBACKS = {
	{ GridCells = 32, BaseCellSize = 4, LevelCount = 7 },
	{ GridCells = 32, BaseCellSize = 4, LevelCount = 6 },
	{ GridCells = 24, BaseCellSize = 8, LevelCount = 5 },
}
Sea.MaxRung = #FALLBACKS
local rung = 0 -- the adaptive quality's rung on screen

local simConfig: any = nil
local simulation: any = nil
local masks: any = nil
local stepConnection: RBXScriptConnection? = nil
local sinceStep = 0
local seaVersion = 0 -- bumped when the wave settings change, so the workers rebuild theirs

local clipmap: any = nil
local pending: any = nil
-- a StartRender asked for while an earlier build is still being cancelled (a burst of setting changes
-- rebuilds several times in a row): it starts when that one finishes
local queued: { any }? = nil
local renderToken = 0
local renderBound = false
local doubleSided = false
local shownNight = -1
local settingsConnection: { Disconnect: (any) -> () }? = nil
local workers: { Actor } = {}
local published: SharedTable? = nil
local publishedFrames = 0

--[=[
	@class Spectral
	@private
]=]

function Sea.Active(): boolean
	return Settings.Get("WaveMode") == "FFT"
end

local function currentTime(): number
	return (workspace:GetServerTimeNow() - TIME_ORIGIN) * Settings.Get("TimeScale")
end

local function seaValues(): any
	return {
		SeaLevel = Settings.Get("SeaLevel"),
		WaveHeight = Settings.Get("FFTWaveHeight"),
		WindSpeed = Settings.Get("FFTWindSpeed"),
		WindAngle = Settings.Get("FFTWindAngle"),
		Chop = Settings.Get("FFTChoppiness"),
		Foam = Settings.Get("FFTFoam"),
		SeaVersion = seaVersion,
	}
end

-- Brings the simulation up to the settings: builds it, or rebuilds the parts that changed.
local function sync()
	local values = seaValues()
	if not simConfig then
		simConfig, simulation = Config.simulation(values)
		simulation:Step(currentTime(), 0)
		return
	end
	if
		simConfig.WaveHeight ~= values.WaveHeight
		or simConfig.WindSpeed ~= values.WindSpeed
		or simConfig.WindDirection ~= values.WindAngle
		or simConfig.Chop ~= values.Chop
		or simConfig.Foam ~= values.Foam
		or simConfig.SeaLevel ~= values.SeaLevel
	then
		seaVersion += 1 -- the workers notice and rebuild theirs
	end
	if Config.update(simConfig, simulation, values) and clipmap then
		clipmap.config.WaveHeight = values.WaveHeight
		clipmap:InvalidatePlacement()
	end
	if clipmap then
		clipmap.config.SeaLevel = values.SeaLevel
	end
end

local function step(dt: number)
	local interval = if RunService:IsServer() then 1 / SERVER_RATE elseif #workers > 0 then 1 / CLIENT_RATE else 0
	sinceStep += dt
	if sinceStep < interval then
		return
	end
	simulation:Step(currentTime(), sinceStep)
	sinceStep = 0
	masks:Update()
end

-- The tagged instances that reshape the water (see Masks); plain data, so the workers build the same
function Sea.MaskSources(): { any }
	return {
		{ Tag = Settings.Get("DryTag"), Mode = "Cutout", Falloff = 0 },
		{ Tag = Settings.Get("ObstacleTag"), Mode = "Calm", Falloff = 40 },
		{ Tag = "OceanMask", Mode = "Calm", Falloff = 12 },
	}
end

--[[
	Called whenever a setting changes (from Waves.Refresh): starts or stops the simulation with the
	mode, and applies changed wave settings. Cheap when nothing changed.
]]
function Sea.Sync()
	if not Sea.Active() then
		if stepConnection then
			stepConnection:Disconnect()
			stepConnection = nil
			simulation, simConfig = nil, nil
			if masks then
				masks:Destroy()
				masks = nil
			end
		end
		return
	end
	sync()
	if not masks then
		masks = Masks.new(Sea.MaskSources())
		masks:Update()
	end
	if not stepConnection then
		sinceStep = 0
		stepConnection = RunService.Heartbeat:Connect(step)
	end
end

-- World Y of the surface above (x, z): the displacement is inverted so the answer is what is drawn there.
function Sea.Height(x: number, z: number): number
	local sea = simConfig and simConfig.SeaLevel or Settings.Get("SeaLevel")
	if not simulation then
		return sea
	end
	local px, pz = x, z
	for _ = 1, 4 do
		local dx, _, dz = simulation:GetDisplacement(px, pz)
		local amplitude = masks:AmplitudeAt(px, sea, pz)
		px, pz = x - dx * amplitude, z - dz * amplitude
	end
	local _, h = simulation:GetDisplacement(px, pz)
	return sea + h * masks:AmplitudeAt(px, sea, pz)
end

-- The surface's offset at the rest point (x, z): dx, dy, dz.
function Sea.Displace(x: number, z: number): (number, number, number)
	if not simulation then
		return 0, 0, 0
	end
	local dx, h, dz = simulation:GetDisplacement(x, z)
	local amplitude = masks:AmplitudeAt(x, simConfig.SeaLevel, z)
	return dx * amplitude, h * amplitude, dz * amplitude
end

-- The tallest crest the sea can have right now (the significant wave height times a little under 1).
function Sea.MaxAmp(): number
	return Settings.Get("FFTWaveHeight") * 0.8
end

---------------------------------------------------------------------------------------------
-- Drawing (client)
---------------------------------------------------------------------------------------------

local function nightFactor(): number
	if not Settings.Get("DynamicLighting") then
		return 1
	end
	local sun = math.clamp((Lighting:GetSunDirection().Y + 0.1) / 0.35, 0, 1)
	local night = Settings.Get("NightBrightness")
	return night + (1 - night) * sun * sun * (3 - 2 * sun)
end

local function wantTextured(): boolean
	return Settings.Get("Lit") and Settings.Get("SurfaceDetail") ~= "None" and rung < 2
end

-- Everything a frame needs, into the SharedTable the workers read (the frame number last: it is what
-- they wait on).
local function publish(camera: Camera, night: number)
	local frame = published :: SharedTable
	local cf = camera.CFrame
	local look, right, up = cf.LookVector, cf.RightVector, cf.UpVector
	local viewport = camera.ViewportSize
	frame.CamX, frame.CamY, frame.CamZ = cf.X, cf.Y, cf.Z
	frame.LookX, frame.LookY, frame.LookZ = look.X, look.Y, look.Z
	frame.RightX, frame.RightY, frame.RightZ = right.X, right.Y, right.Z
	frame.UpX, frame.UpY, frame.UpZ = up.X, up.Y, up.Z
	frame.TanY = math.tan(math.rad(camera.FieldOfView) * 0.5)
	frame.ViewX, frame.ViewY = viewport.X, viewport.Y
	frame.Night, frame.Textured, frame.LOD = night, wantTextured(), Settings.Get("ShowLODColors") == true
	frame.SimTime = currentTime()
	frame.Flow, frame.FlowAngle, frame.FlowTime =
		Settings.Get("SurfaceFlow"), math.rad(simConfig.WindDirection), workspace:GetServerTimeNow()
	frame.SeaVersion = seaVersion
	frame.SeaLevel, frame.WaveHeight, frame.WindSpeed = simConfig.SeaLevel, simConfig.WaveHeight, simConfig.WindSpeed
	frame.WindAngle, frame.Chop, frame.Foam = simConfig.WindDirection, simConfig.Chop, simConfig.Foam
	publishedFrames += 1
	frame.Frame = publishedFrames
end

local function render()
	local camera = workspace.CurrentCamera
	if not (camera and clipmap) then
		return
	end
	local night = nightFactor()
	if published then
		publish(camera, night)
		return
	end
	if math.abs(night - shownNight) > 0.01 then
		shownNight = night
		clipmap:SetNight(night)
	end
	clipmap.flow, clipmap.flowAngle, clipmap.flowTime =
		Settings.Get("SurfaceFlow"), math.rad(simConfig.WindDirection), workspace:GetServerTimeNow()
	clipmap:Update(camera)
end

local function clipmapConfig(quality: any): any
	local material = Enum.Material.SmoothPlastic
	local named = Settings.Get("WaterMaterial")
	local ok, found = pcall(function()
		return Enum.Material[named]
	end)
	if ok and found and found ~= Enum.Material.Air and found ~= Enum.Material.Water then
		material = found
	end
	return {
		GridCells = quality.GridCells,
		BaseCellSize = quality.BaseCellSize,
		LevelCount = quality.LevelCount,
		MipBias = 1.3,
		WaveHeight = simConfig.WaveHeight,
		SeaLevel = simConfig.SeaLevel,
		TileSize = TILE_SIZE,
		DeepColor = Settings.Get("DeepColor"),
		CrestColor = Settings.Get("ShallowColor"),
		FoamColor = Settings.Get("FoamColor"),
		CrestStrength = 0.8, -- light shining through thin crests
		SkyColor = Color3.fromRGB(160, 208, 216), -- the Fresnel tint towards the sky at grazing angles
		SkyReflection = 0.3,
		FoamStrength = 1,
		ShowLODColors = Settings.Get("ShowLODColors"),
		Material = material,
		Reflectance = Settings.Get("Reflectance"),
	}
end

--[[
	The MeshParts of the clipmap (none while it is not built): the Renderer gives them the water's
	material and the ripples like any other surface part.
]]
function Sea.Parts(): { MeshPart }
	return if clipmap then clipmap:Parts() else {}
end

-- Lets the surface be seen from below (the Renderer calls it as the camera goes under)
function Sea.SetDoubleSided(on: boolean)
	doubleSided = on
	if clipmap then
		clipmap:SetDoubleSided(on)
	end
end

--[[
	The parts foaming where they cross the water (from the Contact scan): part of the FFT surface's own
	foam, so it joins what it touches. Sent to the workers only when the list changes.
]]
local sentAuto: any = {}
local function sameList(a: { Instance }, b: { Instance }): boolean
	if #a ~= #b then
		return false
	end
	local seen = {}
	for _, part in a do
		seen[part] = true
	end
	for _, part in b do
		if not seen[part] then
			return false
		end
	end
	return true
end

function Sea.SetAutoFoam(parts: { Instance }, falloff: number, strength: number)
	if not clipmap then
		return
	end
	if #workers == 0 then
		if masks then
			masks:SetAuto(parts, falloff, strength)
		end
		return
	end
	if sentAuto.Falloff ~= falloff or sentAuto.Strength ~= strength or not sameList(parts, sentAuto) then
		sentAuto = table.clone(parts)
		sentAuto.Falloff, sentAuto.Strength = falloff, strength
		for _, actor in workers do
			actor:SendMessage("Auto", parts, falloff, strength)
		end
	end
end

function Sea.Rendering(): boolean
	return clipmap ~= nil
end

-- Whether the drawing is running on worker Actors (for stats and tests)
function Sea.Parallel(): boolean
	return published ~= nil
end

local function stopWorkers()
	for _, actor in workers do
		actor:Destroy()
	end
	table.clear(workers)
	published = nil
	sentAuto = {}
end

--[[
	Hands the built tiles to worker Actors, a share each. Returns false (the main thread draws) when this
	is not a running client, or the Actors never come up.
]]
local function startWorkers(map: any, into: Instance): boolean
	if not (RunService:IsRunning() and RunService:IsClient()) or into:IsA("Camera") then
		return false
	end
	local template = script:FindFirstChild("Worker")
	if not template then
		return false
	end

	local shared = SharedTable.new({ Frame = 0 })
	local records = {}
	for i = 1, WORKERS do
		records[i] = {}
	end
	for index, tile in map.tiles do
		table.insert(records[(index - 1) % WORKERS + 1], map:ExportTile(tile))
	end
	for i = 1, WORKERS do
		local actor = Instance.new("Actor")
		actor.Name = `OceanSpectralWorker{i}`
		actor.Archivable = false
		local worker = template:Clone()
		worker.Parent = actor
		actor.Parent = into
		workers[i] = actor
	end

	local waited = 0
	while waited < 5 do
		local ready = true
		for _, actor in workers do
			ready = ready and actor:GetAttribute("Ready") == true
		end
		if ready then
			break
		end
		waited += task.wait()
	end
	for _, actor in workers do
		if not actor:GetAttribute("Ready") then
			stopWorkers()
			return false
		end
	end

	local state, sea, sources = map:Export(), seaValues(), Sea.MaskSources()
	for i, actor in workers do
		actor:SendMessage("Load", script, shared, state, sea, sources, records[i])
	end
	published = shared
	return true
end

--[[
	Builds the clipmap under `into` (yields while the meshes are made, so it runs on its own thread) and
	draws it every frame. `onBuilt` runs once it is on screen.
]]
function Sea.StartRender(into: Instance, onBuilt: (() -> ())?, level: number?)
	if clipmap then
		return
	end
	if pending then
		queued = { into, onBuilt, level }
		return
	end
	rung = math.clamp(level or 0, 0, #FALLBACKS)
	Sea.Sync()
	if not simulation then
		return
	end
	renderToken += 1
	local token = renderToken
	task.spawn(function()
		local shape = if rung > 0 then FALLBACKS[rung] else QUALITY[Settings.Get("Quality")] or QUALITY.Regular
		local candidate = Clipmap.new(clipmapConfig(shape), simulation, masks, into)
		pending = candidate
		candidate:Build()
		for _, fallback in FALLBACKS do
			if candidate.destroyed or candidate.stats.failedTiles == 0 then
				break
			end
			warn("[Ocean] Not enough EditableMesh memory for the FFT sea on this device: a coarser clipmap")
			for key, value in fallback do
				candidate.config[key] = value
			end
			candidate:Build()
		end
		if token ~= renderToken or candidate.destroyed or candidate.stats.tiles == 0 then
			pending = nil
			candidate:Destroy()
			local next = queued
			queued = nil
			if next then
				Sea.StartRender(next[1], next[2], next[3])
			end
			return
		end
		candidate:SetTextured(wantTextured())
		candidate:SetDoubleSided(doubleSided)
		startWorkers(candidate, into) -- false: the main thread draws it
		pending = nil
		if token ~= renderToken then
			stopWorkers()
			candidate:Destroy()
			local next = queued
			queued = nil
			if next then
				Sea.StartRender(next[1], next[2], next[3])
			end
			return
		end
		clipmap = candidate
		shownNight = -1
		if not renderBound then
			renderBound = true
			RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, render)
		end
		settingsConnection = Settings.OnChanged(function(name)
			if not clipmap then
				return
			end
			if name == "DeepColor" or name == "ShallowColor" or name == "FoamColor" then
				clipmap.config.DeepColor = Settings.Get("DeepColor")
				clipmap.config.CrestColor = Settings.Get("ShallowColor")
				clipmap.config.FoamColor = Settings.Get("FoamColor")
				clipmap:RebuildPalette()
				shownNight = -1
				for _, actor in workers do
					actor:SendMessage(
						"Look",
						clipmap.config.DeepColor,
						clipmap.config.CrestColor,
						clipmap.config.FoamColor
					)
				end
			elseif name == "ShowLODColors" then
				clipmap.config.ShowLODColors = Settings.Get("ShowLODColors")
			elseif name == "SurfaceDetail" or name == "Lit" then
				clipmap:SetTextured(wantTextured())
			end
		end)
		if onBuilt then
			onBuilt()
		end
	end)
end

function Sea.StopRender()
	renderToken += 1
	queued = nil
	if pending then
		pending.destroyed = true
	end
	if renderBound then
		renderBound = false
		RunService:UnbindFromRenderStep(RENDER_NAME)
	end
	if settingsConnection then
		settingsConnection:Disconnect()
		settingsConnection = nil
	end
	stopWorkers()
	if clipmap then
		clipmap:Destroy()
		clipmap = nil
	end
end

return Sea

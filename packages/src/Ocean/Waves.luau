--!native
--!optimize 2
--[[
	Gerstner wave math shared by the renderer (client) and the physics (both sides).
	Deterministic in (settings, weather state, server time), so only those ever replicate.

	Each weather type compiles to a "set": flat wave arrays plus its look (colours, foam). The sea at
	a point is a weighted sum of whole sets - "layers" - never a blend of wave parameters (blending
	wavelengths across space would scramble the phase). Layers = the zones covering that point
	(cross-fading at their rims) + the global weather for whatever weight is left, and each of those
	is two layers while it is transitioning.
]]
local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)
local Spectral = require(script.Parent.Spectral)
local Weather = require(script.Parent.Weather)

--[=[
	@class Waves

	The wave function: Gerstner waves, shared by the renderer (client) and the physics (both sides).
	It is deterministic in the settings, the weather state and server time, so a height sampled on the
	server matches the surface a client sees.

	Each weather compiles to a *set* of six waves plus its look. The sea at a point is a weighted sum of
	whole sets (zones cross-fading at their rims, the global weather for the rest, and two sets while a
	weather is transitioning), never a blend of wave parameters.
]=]
--[=[
	@prop SeaLevel number
	@within Waves
	The `SeaLevel` setting, cached.
]=]
--[=[
	@prop Sets { [string]: Set }
	@within Waves
	Compiled wave sets by weather name.
]=]
--[=[
	@prop Version number
	@within Waves
	Increments every time the sets are recompiled.
]=]
local Waves = {}

local N = Settings.WAVE_COUNT
local CELL_SCALE = { Fast = 2, Regular = 1.25, Realistic = 1 } -- the renderer's cell scale per Quality

export type Set = {
	Name: string,
	Length: { number },
	DirX: { number },
	DirZ: { number },
	Kx: { number },
	Kz: { number },
	Omega: { number },
	Amp: { number },
	Phys: { number }, -- amplitude the physics uses: Amp, less what the mesh is too coarse to draw
	MaxAmp: number, -- tallest possible crest (all waves in phase)
	Look: { [string]: any }, -- the non-wave weather settings, resolved
}

Waves.Sets = {} :: { [string]: Set }
Waves.SeaLevel = 0
Waves.MaxLength = 1 -- longest wavelength in any set (the renderer's "can this vertex move at all" bound)
Waves.MaxAmp = 0 -- tallest possible crest in any set (the renderer's off-screen margin)
Waves.Version = 0 -- bumps on every Refresh

-- Scratch output of Gather: layer i is LayerSets[i] at LayerWeights[i]. Reused, never allocate per call.
Waves.LayerSets = {} :: { Set }
Waves.LayerWeights = {} :: { number }

local timeScale = 1
local zones = {} :: { any } -- compiled: { X, Z, Radius, Inner, State = Weather.Zone }

local function buildSet(name: string): Set
	local look = Weather.Resolve(name)
	local set = {
		Name = name,
		Length = table.create(N, 1),
		DirX = table.create(N, 1),
		DirZ = table.create(N, 0),
		Kx = table.create(N, 0),
		Kz = table.create(N, 0),
		Omega = table.create(N, 0),
		Amp = table.create(N, 0),
		Phys = table.create(N, 0),
		MaxAmp = 0,
		Look = look,
	}
	local g = look.WaveGravity
	-- UseWind: the configured angles become offsets around the wind direction (0 wind = as configured)
	local windAngle = 0
	if Settings.Get("UseWind") then
		local wind = workspace.GlobalWind
		if wind.X ~= 0 or wind.Z ~= 0 then
			windAngle = math.atan2(wind.Z, wind.X)
		end
	end
	-- WaveHeight scales the whole wave field: wavelength as well as amplitude, so a giant sea keeps
	-- the same steepness and the crests never fold over (Gerstner loops appear past steepness 1).
	local scale = math.max(look.WaveHeight, 1e-3)
	-- The finest cell the mesh has (CellSize x the quality's scale). A wave shorter than three cells
	-- cannot be drawn and fades in up to six; heights, buoyancy and swimming use the same fade, so
	-- things float on the water you see and not on chop the mesh never shows.
	local cell = Settings.Get("CellSize") * (CELL_SCALE[Settings.Get("Quality")] or 1)
	for i = 1, N do
		local angle = math.rad(look[`Wave{i}Angle`]) + windAngle
		local length = look[`Wave{i}Length`] * scale
		local k = 2 * math.pi / length
		local dx, dz = math.cos(angle), math.sin(angle)
		set.Length[i] = length
		set.DirX[i], set.DirZ[i] = dx, dz
		set.Kx[i], set.Kz[i] = k * dx, k * dz
		set.Omega[i] = math.sqrt(g * k) -- deep-water dispersion
		set.Amp[i] = look[`Wave{i}Steepness`] / k
		set.Phys[i] = set.Amp[i] * math.clamp(length / (3 * cell) - 1, 0, 1)
		set.MaxAmp += set.Amp[i]
	end
	set.MaxAmp = math.max(set.MaxAmp, 1e-3)
	return set
end

-- The dynamic sea is an EditableMesh, which an experience has to allow (Experience Settings).
-- Without it there is no wave mesh, so the sea is flat for everyone: visuals and physics alike.
local meshAccess: boolean? = nil
--[=[
	@within Waves
	Whether this experience may create EditableMeshes. When it may not, the sea falls back to a
	flat surface at `SeaLevel` (as if `FlatSea` were on) and the wave mesh is never built.
	@return boolean
]=]
function Waves.MeshAvailable(): boolean
	if meshAccess == nil then
		meshAccess = pcall(function()
			AssetService:CreateEditableMesh():Destroy()
		end)
	end
	return meshAccess :: boolean
end

local flat = false -- FlatSea (or no EditableMesh access): no displacement anywhere, the surface is SeaLevel
local localFlat = false -- this client is drawing the flat fallback: its own queries are flat too

--[=[
	@within Waves
	@client
	Makes this client's sea flat (heights, swimming and the tint follow the flat surface it is
	drawing) without touching the setting. The renderer turns it on while a device cannot hold the
	wave mesh and off again once it can.
	@param on boolean
]=]
function Waves.SetLocalFlat(on: boolean)
	if localFlat ~= on then
		localFlat = on
		Waves.Refresh()
	end
end
local frozen = false -- StaticWaves: the wave clock holds, so the surface never moves

--[=[
	@within Waves
	Recompiles every weather into wave sets from the current settings and weather state. Runs
	automatically whenever a setting or the weather changes.
]=]
function Waves.Refresh()
	Weather.Decode()
	flat = Settings.Get("FlatSea") == true or localFlat or not Waves.MeshAvailable()
	frozen = Settings.Get("StaticWaves") == true
	table.clear(Waves.Sets)
	Waves.MaxLength, Waves.MaxAmp = 1, 0
	for _, name in Weather.Names() do
		local set = buildSet(name)
		Waves.Sets[name] = set
		Waves.MaxLength = math.max(Waves.MaxLength, table.unpack(set.Length))
		Waves.MaxAmp = math.max(Waves.MaxAmp, set.MaxAmp)
	end

	table.clear(zones)
	for _, zone in Weather.State.Zones do
		table.insert(
			zones,
			{ X = zone.X, Z = zone.Z, Radius = zone.Radius, Inner = zone.Radius - zone.Blend, State = zone }
		)
	end

	Waves.SeaLevel = Settings.Get("SeaLevel")
	timeScale = Settings.Get("TimeScale")
	-- the FFT sea has its own wave field: the tallest crest and a wavelength the mesh never has to fade
	Spectral.Sync()
	if Spectral.Active() then
		Waves.MaxAmp = Spectral.MaxAmp()
		Waves.MaxLength = 1000
	end
	Waves.Version += 1
end

---------------------------------------------------------------------------------------------
-- Obstacles: tag a BasePart or Model "OceanObstacle" and the sea calms against it instead of
-- washing through. Each is its box's footprint in XZ, grown by `OceanShore` studs (attribute,
-- default 40): inside that outset the water is calmed by OceanCalmness (attribute, 0..1: 1 = flat,
-- 0 = the waves pass untouched), and over the next Shore studs the waves ease back to full. Same
-- function on both sides, so floats and swimmers calm down at the shore too. Refreshed twice a second.
---------------------------------------------------------------------------------------------

local DEFAULT_SHORE = 40
local obstacles = {} :: { any } -- { X, Z, Radius, Shore, Calmness, RX, RZ, LX, LZ, HalfX, HalfZ }
local obstacleTimer = 0

--[=[
	@within Waves
	Re-reads every `OceanObstacle` in the workspace. Runs twice a second on its own.
]=]
function Waves.RefreshObstacles()
	table.clear(obstacles)
	for _, instance in CollectionService:GetTagged(Settings.Get("ObstacleTag")) do
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
		-- XZ extent of the rotated box, as a circle
		local right, look = cframe.RightVector, cframe.LookVector
		local ex = math.abs(right.X) * size.X + math.abs(cframe.UpVector.X) * size.Y + math.abs(look.X) * size.Z
		local ez = math.abs(right.Z) * size.X + math.abs(cframe.UpVector.Z) * size.Y + math.abs(look.Z) * size.Z
		local shore = instance:GetAttribute("OceanShore")
		local calmness = instance:GetAttribute("OceanCalmness")
		table.insert(obstacles, {
			X = cframe.Position.X,
			Z = cframe.Position.Z,
			Radius = math.sqrt(ex * ex + ez * ez) / 2, -- bounding circle, for the near-lists only
			Shore = math.max(if typeof(shore) == "number" then shore else DEFAULT_SHORE, 1),
			-- 1 = flat against it, 0 = the waves pass this obstacle untouched
			Calmness = math.clamp(if typeof(calmness) == "number" then calmness else 1, 0, 1),
			RX = right.X,
			RZ = right.Z,
			LX = look.X,
			LZ = look.Z,
			HalfX = size.X / 2,
			HalfZ = size.Z / 2,
		})
	end
end

-- Obstacles whose calming ring touches the circle (x, z, radius); nothing = all of them.
--[=[
	@within Waves
	Obstacles whose calming ring touches the circle `(x, z, radius)`; with no arguments, all of them.
	@param x number?
	@param z number?
	@param radius number?
	@return { any }
]=]
function Waves.ObstaclesNear(x: number?, z: number?, radius: number?): { any }
	if not x then
		return obstacles
	end
	local near = {}
	for _, o in obstacles do
		local dx, dz = o.X - x, o.Z - (z :: number)
		local reach = o.Radius + o.Shore + (radius :: number)
		if dx * dx + dz * dz < reach * reach then
			table.insert(near, o)
		end
	end
	return near
end

-- 1 = open water, 1 - OceanCalmness = against the obstacle; a gentle (quintic) fade across the shore
-- ring in between, so the sea settles into the shore instead of going flat at a line.
--[=[
	@within Waves
	The wave multiplier at `(x, z)` from the given obstacles: 1 in open water, down to
	`1 - OceanCalmness` against an obstacle, easing across its shore ring.
	@param list { any } -- from [Waves.ObstaclesNear]
	@param x number
	@param z number
	@return number
]=]
function Waves.Damp(list: { any }, x: number, z: number): number
	local factor = 1
	for _, o in list do
		-- signed distance to the box footprint: positive outside, negative inside
		local dx, dz = x - o.X, z - o.Z
		local lx = dx * o.RX + dz * o.RZ
		local lz = dx * o.LX + dz * o.LZ
		local ox, oz = math.abs(lx) - o.HalfX, math.abs(lz) - o.HalfZ
		local d = if ox > 0 or oz > 0 then math.sqrt(math.max(ox, 0) ^ 2 + math.max(oz, 0) ^ 2) else math.max(ox, oz)
		-- fully calmed out to Shore studs beyond the edge, then the waves come back over another Shore
		if d < 2 * o.Shore then
			local s = math.clamp((d - o.Shore) / o.Shore, 0, 1)
			local ease = s * s * s * (s * (6 * s - 15) + 10)
			factor = math.min(factor, 1 - o.Calmness * (1 - ease))
		end
	end
	return factor
end

local function tickObstacles(dt: number)
	obstacleTimer += dt
	if obstacleTimer >= 0.5 then
		obstacleTimer = 0
		Waves.RefreshObstacles()
	end
end

local connections: { any } = {}

--[=[
	@within Waves
	@private
]=]
function Waves.Init()
	if #connections > 0 then
		return
	end
	Waves.Refresh()
	Waves.RefreshObstacles()
	table.insert(connections, Settings.OnChanged(Waves.Refresh)) -- any setting, or the replicated weather state
	table.insert(connections, RunService.Heartbeat:Connect(tickObstacles))
	table.insert(connections, workspace:GetPropertyChangedSignal("GlobalWind"):Connect(Waves.Refresh))
end

--[=[
	@within Waves
	@private
]=]
function Waves.Stop()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

-- Synced wave clock. (Weather fades use unscaled server time.)
--[=[
	@within Waves
	The synced wave clock: server time times `TimeScale`, or 0 while `StaticWaves` is on.
	@return number
]=]
function Waves.Time(): number
	if frozen then
		return 0
	end
	return workspace:GetServerTimeNow() * timeScale
end

-- Zones whose disc touches the circle (x, z, radius): the renderer culls once per frame so its
-- per-vertex Gather only ever walks the few zones on screen. Pass nothing to get them all.
-- Linear scan. It runs once per frame, not per vertex, so it is fine into the thousands
-- of zones; drop an octree in here if you ever really have that many.
--[=[
	@within Waves
	Scripted weather zones whose disc touches the circle `(x, z, radius)`; with no arguments, all of them.
	@param x number?
	@param z number?
	@param radius number?
	@return { any }
]=]
function Waves.ZonesNear(x: number?, z: number?, radius: number?): { any }
	if not x then
		return zones
	end
	local near = {}
	for _, zone in zones do
		local dx, dz = zone.X - x, zone.Z - (z :: number)
		local reach = zone.Radius + (radius :: number)
		if dx * dx + dz * dz < reach * reach then
			table.insert(near, zone)
		end
	end
	return near
end

--[=[
	@within Waves
	True while the global weather is mid-transition.
	@param now number -- `workspace:GetServerTimeNow()`
	@return boolean
]=]
function Waves.IsBlending(now: number): boolean
	return Weather.Alpha(Weather.State.Global, now) < 1
end

local function push(count: number, blend: any, weight: number, now: number): number
	local alpha = Weather.Alpha(blend, now)
	local sets, weights = Waves.LayerSets, Waves.LayerWeights
	if not Waves.Sets[Weather.DEFAULT] then
		Waves.Refresh() -- asked before Init (a script requiring the module early): compile now
	end
	local current = Waves.Sets[blend.Current] or Waves.Sets[Weather.DEFAULT]
	if alpha < 1 then
		count += 1
		sets[count] = Waves.Sets[blend.Previous] or current
		weights[count] = weight * (1 - alpha)
	end
	count += 1
	sets[count] = current
	weights[count] = weight * alpha
	return count
end

-- Fills LayerSets/LayerWeights for the point and returns the layer count. Weights sum to 1.
--[=[
	@within Waves
	Fills `Waves.LayerSets` and `Waves.LayerWeights` with the wave sets that apply at `(x, z)` and
	returns how many there are. The weights sum to 1.
	@param zoneList { any } -- from [Waves.ZonesNear]
	@param x number
	@param z number
	@param now number -- `workspace:GetServerTimeNow()`
	@return number
]=]
function Waves.Gather(zoneList: { any }, x: number, z: number, now: number): number
	local count, covered = 0, 0
	for _, zone in zoneList do
		local dx, dz = x - zone.X, z - zone.Z
		local d2 = dx * dx + dz * dz
		if d2 < zone.Radius * zone.Radius then
			local t = math.clamp((math.sqrt(d2) - zone.Inner) / (zone.Radius - zone.Inner), 0, 1)
			local weight = 1 - t * t * (3 - 2 * t)
			covered += weight
			count = push(count, zone.State, weight, now)
		end
	end
	if covered > 1 then -- overlapping zones: share the point between them
		for i = 1, count do
			Waves.LayerWeights[i] /= covered
		end
	elseif covered < 1 then
		count = push(count, Weather.State.Global, 1 - covered, now)
	end
	return count
end

local function displaceSet(set: Set, x: number, z: number, t: number): (number, number, number)
	local ox, oy, oz = 0, 0, 0
	local kx, kz, omega, amp, dirX, dirZ = set.Kx, set.Kz, set.Omega, set.Phys, set.DirX, set.DirZ
	for i = 1, N do
		local f = kx[i] * x + kz[i] * z - omega[i] * t
		local a = amp[i]
		local c = math.cos(f) * a
		ox += dirX[i] * c
		oz += dirZ[i] * c
		oy += math.sin(f) * a
	end
	return ox, oy, oz
end

-- Sum of the gathered layers at (x, z): call after Waves.Gather.
local function displaceGathered(count: number, x: number, z: number, time: number): (number, number, number)
	local ox, oy, oz = 0, 0, 0
	for i = 1, count do
		local weight = Waves.LayerWeights[i]
		local dx, dy, dz = displaceSet(Waves.LayerSets[i], x, z, time)
		ox += dx * weight
		oy += dy * weight
		oz += dz * weight
	end
	return ox, oy, oz
end

--[=[
	@within Waves
	Displacement of the surface point that rests at `(x, z)`: how far it has been pushed along X, up
	along Y and along Z. Zero everywhere while `FlatSea` is on.
	@param x number
	@param z number
	@param t number? -- wave clock (default: now)
	@param now number? -- server time (default: now)
	@return number -- X offset
	@return number -- Y offset
	@return number -- Z offset
]=]
function Waves.Displace(x: number, z: number, t: number?, now: number?): (number, number, number)
	if flat then
		return 0, 0, 0
	end
	if Spectral.Active() then
		return Spectral.Displace(x, z)
	end
	local clock = now or workspace:GetServerTimeNow()
	local time = t or clock * timeScale
	local ox, oy, oz = displaceGathered(Waves.Gather(zones, x, z, clock), x, z, time)
	if #obstacles > 0 then
		local damp = Waves.Damp(obstacles, x, z)
		ox, oy, oz = ox * damp, oy * damp, oz * damp
	end
	return ox, oy, oz
end

-- World-space surface height above (x, z). Gerstner waves shove points sideways, so we
-- fixed-point iterate to find which rest point landed on (x, z). 3 rounds is sub-0.25 stud.
--[=[
	@within Waves
	World Y of the surface above `(x, z)`. Gerstner waves move points sideways, so this iterates to find
	the rest point that lands on `(x, z)`; the answer is within a quarter stud. [Ocean:GetHeight] calls this.
	@param x number
	@param z number
	@param t number? -- wave clock (default: now)
	@param now number? -- server time (default: now)
	@return number
]=]
function Waves.Height(x: number, z: number, t: number?, now: number?): number
	if flat then
		return Waves.SeaLevel
	end
	if Spectral.Active() then
		return Spectral.Height(x, z)
	end
	local clock = now or workspace:GetServerTimeNow()
	local time = t or clock * timeScale
	-- the layer weights and the obstacle damping vary over tens of studs, the rest point over a
	-- few: sample both once at (x, z) and reuse them for every round
	local count = Waves.Gather(zones, x, z, clock)
	local damp = if #obstacles > 0 then Waves.Damp(obstacles, x, z) else 1
	local px, pz = x, z
	local dy = 0
	for _ = 1, 3 do
		local dx, y, dz = displaceGathered(count, px, pz, time)
		px, pz, dy = x - dx * damp, z - dz * damp, y * damp
	end
	return Waves.SeaLevel + dy
end

-- One weather setting blended at a point (numbers only), e.g. Waves.LookNumber("SplashRate", x, z).
--[=[
	@within Waves
	One numeric weather setting blended at a point, for example `Waves.LookNumber("SplashRate", x, z)`.
	`"MaxAmp"` gives the tallest possible crest there.
	@param name string
	@param x number
	@param z number
	@return number
]=]
function Waves.LookNumber(name: string, x: number, z: number): number
	if name == "MaxAmp" and Spectral.Active() then
		return Spectral.MaxAmp()
	end
	local count = Waves.Gather(zones, x, z, workspace:GetServerTimeNow())
	local value = 0
	for i = 1, count do
		local set = Waves.LayerSets[i]
		value += (if name == "MaxAmp" then set.MaxAmp else set.Look[name]) * Waves.LayerWeights[i]
	end
	return value
end

-- Self-check: `require(game.ReplicatedStorage.Ocean.Waves).SelfTest()` in the command bar.
--[=[
	@within Waves
	Checks that [Waves.Height] inverts [Waves.Displace] and that layer weights sum to 1. Run it from the
	command bar: `require(game.ReplicatedStorage.Ocean.Waves).SelfTest()`.
	@return string
]=]
function Waves.SelfTest(): string
	Waves.Refresh()
	local t = 1234.5
	for _ = 1, 200 do
		local x, z = math.random(-5000, 5000), math.random(-5000, 5000)
		local dx, dy, dz = Waves.Displace(x, z, t)
		-- the surface point that started at (x, z) sits at (x + dx, z + dz); Height() must find it again
		local h = Waves.Height(x + dx, z + dz, t)
		local tolerance = 0.03 * Waves.Sets[Weather.DEFAULT].MaxAmp -- the error scales with the sea
		assert(math.abs(h - (Waves.SeaLevel + dy)) < tolerance, `Height() inverse off by {h - Waves.SeaLevel - dy}`)
	end
	for _ = 1, 50 do -- layer weights must always sum to 1, zones or not
		local count =
			Waves.Gather(zones, math.random(-5000, 5000), math.random(-5000, 5000), workspace:GetServerTimeNow())
		local sum = 0
		for i = 1, count do
			sum += Waves.LayerWeights[i]
		end
		assert(math.abs(sum - 1) < 1e-6, `layer weights sum to {sum}`)
	end
	return "Waves.SelfTest ok"
end

return Waves

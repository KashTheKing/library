--!native
--!optimize 2
--[[
	Client-only. Draws the wave mesh the Renderer built, for a share of its lattice points: each
	update, the waves at every point (with the LOD fade, the edge fade, obstacle damping, the
	re-centre easing and the dry-region cut) onto its bones, and the foam's positions and colours
	and the film's bones on the same points.

	It runs in parallel. The Renderer starts a few Actors (Worker.server.luau), each with its own copy
	of this module and its own share of the points (spread by a hash of the point, so every share
	has some of each ring): Step does the maths in the parallel phase, Write the Bone.Transform and
	EditableMesh writes after task.synchronize (neither may be written in parallel). The Renderer
	publishes each update's frame (camera, re-centre, time, passes) in a SharedTable; a worker
	shares nothing else, so nothing big crosses between them. Where Actors can't run (the plugin's
	Edit-mode preview) the Renderer runs one copy itself over every point.

	The re-centre easing needs the surface the old lattice drew at a point's new place. That is a
	function of the world position, the camera and the time, so each copy works it out itself from
	the old lattice's points instead of asking another worker for them.
]]
local Regions = require(script.Parent.Regions)
local Settings = require(script.Parent.Settings)
local Waves = require(script.Parent.Waves)

local Draw = {}

local N = Settings.WAVE_COUNT
local NO_ZONES = {}
local VALUES = 8 -- per morphing vertex: displacement x, y, z, then the five normal sums
-- Vertices outside the camera's view (with a margin for their cell and the waves' reach) update every
-- Nth frame only, a different Nth each frame: still close to right when the camera turns onto them.
local OFFSCREEN_EVERY = 4
local OFFSCREEN_MARGIN = 8 -- studs, on top of two cells and twice the wave height
-- Dry regions cut the lattice only where its cells are at most this many times the finest: a coarser
-- lattice can't follow a box's walls, and would be dragged whole cells toward them.
local CUT_CELLS = 4

--[=[
	@class Draw
	@private
	The wave mesh's per-frame drawing, run in parallel by the Renderer's workers.
]=]

-- What the Renderer hands over after a build (copied to each worker once).
export type Data = {
	Build: number, -- which build this is: a frame of another build is not drawn
	N: number, -- lattice points per side
	Coords: { number }, -- the lattice axis
	-- (every table dense, false where there is nothing: a message to an Actor copies a table with
	-- gaps only up to its first gap)
	Skinned: { boolean }, -- lattice point -> it has a bone
	Blend: { { number } | false }, -- lattice point -> the two bone points it rides, and A's weight
	X: { number }, -- per tile vertex (a point on a tile border is in here once per tile)
	Z: { number },
	Inv: { number }, -- 1 / (3 x the largest adjacent cell)
	Lattice: { number },
	Bones: { Bone | false }, -- per vertex: its skin bone
	FoamMesh: EditableMesh?,
	FoamIds: { number },
	FoamColorIds: { number },
	FoamX: { number },
	FoamZ: { number },
	FoamLattice: { number },
	FilmBones: { Bone },
	FilmLattice: { number },
	Roots: { Bone }, -- per tile: carries the re-centre for the vertices with no bone of their own
	Static: MeshPart?, -- the bone-free outer mesh, moved by its CFrame
	LodCell: number,
	LodInner: number,
	LodSlope: number,
	LodCap: number,
	SkinFadeFrom: number,
	SkinFadeTo: number,
	FoamFadeFrom: number,
	FoamFadeTo: number,
}

-- One update's frame, as the Renderer publishes it.
export type Frame = {
	Build: number,
	Frame: number,
	Ox: number, -- the mesh centre (re-centred by whole texture tiles)
	Oz: number,
	Moved: boolean, -- re-centred this frame: every vertex is placed
	Morph: boolean, -- ...by a few tiles: the old surface eases into the new
	ShiftX: number,
	ShiftZ: number,
	Easing: number, -- 1 at a re-centre, down to 0 over MORPH_TIME
	T: number, -- the wave clock
	Now: number, -- the server time
	SeaLevel: number,
	Flat: boolean,
	Shading: number,
	FarPass: boolean,
	ColorPass: boolean,
	Refresh: boolean, -- re-read the obstacle damping
	Radius: number, -- the animated area's reach
	Night: number,
	Fx: number, -- the camera
	Fy: number,
	Fz: number,
	RX: number,
	RY: number,
	RZ: number,
	UX: number,
	UY: number,
	UZ: number,
	KX: number,
	KY: number,
	KZ: number,
	TanH: number,
	TanV: number,
	SecH: number,
	SecV: number,
}

local FRAME_KEYS = {
	"Build",
	"Frame",
	"Ox",
	"Oz",
	"Moved",
	"Morph",
	"ShiftX",
	"ShiftZ",
	"Easing",
	"T",
	"Now",
	"SeaLevel",
	"Flat",
	"Shading",
	"FarPass",
	"ColorPass",
	"Refresh",
	"Radius",
	"Night",
	"Fx",
	"Fy",
	"Fz",
	"RX",
	"RY",
	"RZ",
	"UX",
	"UY",
	"UZ",
	"KX",
	"KY",
	"KZ",
	"TanH",
	"TanV",
	"SecH",
	"SecV",
}

local data: Data? = nil
local index, count = 1, 1 -- this copy's share: lattice points whose hash lands on `index` of `count`
local seenVersion = -1
local placeIdle = false -- the idle list changed: put its bones at the re-centre offset
local near: { number } = {} -- this share's full-detail vertices some wave moves: every update
local far: { number } = {} -- ...its LOD-ring vertices: on far passes
local idle: { number } = {} -- ...its skinned vertices no wave moves: placed on re-centre only
local foamMine: { number } = {}
local filmMine: { number } = {}
local dampOf: { number? } = {} -- vertex -> obstacle damp, nil = open water
local foamDamp: { number? } = {}
local obstacles: { any } = {}
local morphOff: { number } = {} -- vertex -> old surface minus own sample, easing to 0
-- Written by lattice point every frame, all out of order: sized up front so they are arrays (a
-- table grown that way is a hash, and its writes cost more than the wave sum)
local drawnCF: { CFrame } = {} -- lattice point -> its bone's Transform (waves, fades, dry cut)
local drawnFrame: { number } = {} -- lattice point -> the frame drawnCF was set
local drawnY: { number } = {} -- lattice point -> its height before the dry cut (the foam's amount)
local foamKeys: { number } = {}
local foamAlphas: { number } = {}
local dryIdle: { [number]: boolean } = {} -- idle vertices a dry box moved last frame (to put back)
local dryNow: { Regions.Box } = {}

-- the writes Step leaves for Write
local outBones: { Bone } = {}
local outCF: { CFrame } = {}
local outCount = 0
local posIds: { number } = {}
local posValues: { Vector3 } = {}
local posCount = 0
local colIds: { number } = {}
local colValues: { Color3 } = {}
local colAlphas: { number } = {}
local colCount = 0
local recentre: CFrame? = nil -- the roots' re-centre offset, written by the first share only
local recentreStatic: CFrame? = nil -- ...and the static mesh's CFrame

-- blended look for the current vertex / frame (flat, to stay allocation-free in the hot loop)
local lookMaxAmp, lookFoamStart, lookFoamFull, lookFoamOpacity, lookWebOpacity = 1, 0, 1, 1, 0
local deepR, deepG, deepB, shallowR, shallowG, shallowB, foamR, foamG, foamB = 0, 0, 0, 0, 0, 0, 1, 1, 1

-- Blend the look of the first `count` gathered layers into the look* locals.
local function blendLook(layers: number)
	local sets, weights = Waves.LayerSets, Waves.LayerWeights
	lookMaxAmp, lookFoamStart, lookFoamFull, lookFoamOpacity, lookWebOpacity = 0, 0, 0, 0, 0
	deepR, deepG, deepB, shallowR, shallowG, shallowB, foamR, foamG, foamB = 0, 0, 0, 0, 0, 0, 0, 0, 0
	for i = 1, layers do
		local set, w = sets[i], weights[i]
		local look = set.Look
		local deep, shallow, foam = look.DeepColor, look.ShallowColor, look.FoamColor
		lookMaxAmp += set.MaxAmp * w
		lookFoamStart += look.FoamStart * w
		lookFoamFull += look.FoamFull * w
		lookFoamOpacity += look.FoamOpacity * w
		lookWebOpacity += look.WebOpacity * w
		deepR += deep.R * w
		deepG += deep.G * w
		deepB += deep.B * w
		shallowR += shallow.R * w
		shallowG += shallow.G * w
		shallowB += shallow.B * w
		foamR += foam.R * w
		foamG += foam.G * w
		foamB += foam.B * w
	end
end

local flatSea = false -- FlatSea: no displacement anywhere; everything else (look, foam, film, tint) stays

-- Per-frame gather state for the wave sum (module locals: the hot loop allocates nothing)
local gCount = 0
local gGlobalLoaded = true
local gZones: { any } = NO_ZONES
local gNow = 0

-- Layers for the point: zones near the mesh force per-vertex gathering, only for the vertices
-- actually inside one; everyone else shares the global blend.
local function gatherAt(wx: number, wz: number)
	if #gZones == 0 then
		return
	end
	local zoned = false
	for _, zone in gZones do
		local zx, zz = wx - zone.X, wz - zone.Z
		if zx * zx + zz * zz < zone.Radius * zone.Radius then
			zoned = true
			break
		end
	end
	if zoned then
		gCount = Waves.Gather(gZones, wx, wz, gNow)
		blendLook(gCount)
		gGlobalLoaded = false
	elseif not gGlobalLoaded then
		gCount = Waves.Gather(NO_ZONES, wx, wz, gNow)
		blendLook(gCount)
		gGlobalLoaded = true
	end
end

-- Gerstner sum at a world point with the LOD fade for that point's spacing (inv); no damping.
-- Returns the displacement, then the five sums the surface's normal is made of (see boneCFrame):
-- the height's slope along X and Z, and how much the sideways shove stretches or squeezes the
-- surface (XX, XZ, ZZ). All eight scale together with the wave amplitudes.
local function waveAt(
	wx: number,
	wz: number,
	inv: number,
	t: number
): (number, number, number, number, number, number, number, number)
	if flatSea then -- FlatSea: the same sea, its surface level (the tiles rest at zero displacement)
		return 0, 0, 0, 0, 0, 0, 0, 0
	end
	local sets, weights = Waves.LayerSets, Waves.LayerWeights
	local cos, sin = math.cos, math.sin
	local dx, dy, dz = 0, 0, 0
	local gx, gz, sxx, sxz, szz = 0, 0, 0, 0, 0
	for i = 1, gCount do
		local set, layerWeight = sets[i], weights[i]
		local length, kx, kz, omega, amp, dirX, dirZ =
			set.Length, set.Kx, set.Kz, set.Omega, set.Amp, set.DirX, set.DirZ
		for w = 1, N do
			local lod = length[w] * inv - 1
			if lod > 0 then
				local f = kx[w] * wx + kz[w] * wz - omega[w] * t
				local a = amp[w] * layerWeight * (if lod > 1 then 1 else lod)
				local c = cos(f) * a
				local s = sin(f) * a
				local ux, uz = dirX[w], dirZ[w]
				local waveX, waveZ = kx[w], kz[w]
				dx += ux * c
				dz += uz * c
				dy += s
				gx += waveX * c
				gz += waveZ * c
				sxx += ux * waveX * s
				sxz += ux * waveZ * s
				szz += uz * waveZ * s
			end
		end
	end
	return dx, dy, dz, gx, gz, sxx, sxz, szz
end

-- The bone of a vertex at (x, y, z) in its part's space: the offset AND a turn. Skinning lights a
-- vertex by its bone's rotation, never its offset, so a bone that only moved would leave the whole
-- sea lit like a flat sheet. The turn takes +Y onto the displaced surface's exact normal: the
-- cross product of its two tangents, (1 - XX, slope X, -XZ) along X and (-XZ, slope Z, 1 - ZZ)
-- along Z. `m` is how much of the wave reaches this vertex (fades, damping; 0 = flat), times
-- WaveShading. The quaternion is the shortest turn from +Y onto that normal.
local shading = 1 -- WaveShading, per frame
local function boneCFrame(
	x: number,
	y: number,
	z: number,
	m: number,
	gx: number,
	gz: number,
	sxx: number,
	sxz: number,
	szz: number
): CFrame
	m *= shading
	gx, gz, sxx, sxz, szz = gx * m, gz * m, sxx * m, sxz * m, szz * m
	local nx = -gz * sxz - gx * (1 - szz)
	local ny = math.max((1 - sxx) * (1 - szz) - sxz * sxz, 0.05) -- a folding crest never turns over
	local nz = -gx * sxz - gz * (1 - sxx)
	local w = math.sqrt(nx * nx + ny * ny + nz * nz) + ny
	local s = 1 / math.sqrt(nx * nx + nz * nz + w * w)
	return CFrame.new(x, y, z, nz * s, 0, -nx * s, w * s)
end

-- The surface as drawn at a world point this frame, before the dry cut: the waves at the LOD fade
-- for its distance from the camera, the edge fade and the obstacle damping. Eight values, as waveAt.
local function sample(
	d: Data,
	p: Frame,
	wx: number,
	wz: number,
	damp: number?
): (number, number, number, number, number, number, number, number)
	local ddx, ddz = wx - p.Fx, wz - p.Fz
	local dist = math.sqrt(ddx * ddx + ddz * ddz)
	local inv = 1 / (3 * math.min(d.LodCell + math.max(dist - d.LodInner, 0) * d.LodSlope, d.LodCap))
	gatherAt(wx, wz)
	local dx, dy, dz, gx, gz, sxx, sxz, szz = waveAt(wx, wz, inv, p.T)
	local fade = 1
	if dist > d.SkinFadeFrom then
		local ft = math.clamp((dist - d.SkinFadeFrom) / (d.SkinFadeTo - d.SkinFadeFrom), 0, 1)
		fade = 1 - ft * ft * (3 - 2 * ft)
	end
	if damp then
		fade *= damp
	end
	return dx * fade, dy * fade, dz * fade, gx * fade, gz * fade, sxx * fade, sxz * fade, szz * fade
end

-- The lattice axis cell holding local coordinate x: its lower index and x's place across it (0 = outside).
local function locate(c: { number }, n: number, x: number): (number, number)
	if x < c[1] or x > c[n] then
		return 0, 0
	end
	local lo, hi = 1, n - 1
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if c[mid] <= x then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return lo, (x - c[lo]) / (c[lo + 1] - c[lo])
end

-- What the old lattice drew: accumulated into these, weighted, point by point
local o1, o2, o3, o4, o5, o6, o7, o8 = 0, 0, 0, 0, 0, 0, 0, 0
local function addPoint(d: Data, p: Frame, at: number, weight: number)
	local n, c = d.N, d.Coords
	local wx = p.Ox - p.ShiftX + c[(at - 1) % n + 1] -- where it was: around the old centre
	local wz = p.Oz - p.ShiftZ + c[(at - 1) // n + 1]
	local damp = if #obstacles > 0 then Waves.Damp(obstacles, wx, wz) else 1
	local a1, a2, a3, a4, a5, a6, a7, a8 = sample(d, p, wx, wz, if damp < 1 then damp else nil)
	o1, o2, o3, o4 = o1 + a1 * weight, o2 + a2 * weight, o3 + a3 * weight, o4 + a4 * weight
	o5, o6, o7, o8 = o5 + a5 * weight, o6 + a6 * weight, o7 + a7 * weight, o8 + a8 * weight
end
local function addOld(d: Data, p: Frame, L: number, w: number)
	if w < 1e-6 then
		return
	end
	if d.Skinned[L] then
		addPoint(d, p, L, w)
	else
		local pair = d.Blend[L]
		if pair then -- it rode two bones
			addPoint(d, p, pair[1], w * pair[3])
			addPoint(d, p, pair[2], w * (1 - pair[3]))
		end -- else at rest past the skin: nothing
	end
end

-- The old surface at vertex v's new place (bilinear across the old cell it now sits in), or false
-- when it is off the old lattice or on exactly the same point (then it drew the same: no easing).
local function oldSurface(d: Data, p: Frame, v: number): boolean
	local n, c = d.N, d.Coords
	local L = d.Lattice[v]
	local j, tx = locate(c, n, c[(L - 1) % n + 1] + p.ShiftX)
	local k, tz = locate(c, n, c[(L - 1) // n + 1] + p.ShiftZ)
	if j == 0 or k == 0 then
		return false
	end
	if tx > 1 - 1e-6 then
		j, tx = j + 1, 0
	elseif tx < 1e-6 then
		tx = 0
	end
	if tz > 1 - 1e-6 then
		k, tz = k + 1, 0
	elseif tz < 1e-6 then
		tz = 0
	end
	local a = (k - 1) * n + j
	if tx == 0 and tz == 0 and d.Skinned[a] then
		return false -- the uniform inner area: the old lattice had a bone right here
	end
	o1, o2, o3, o4, o5, o6, o7, o8 = 0, 0, 0, 0, 0, 0, 0, 0
	addOld(d, p, a, (1 - tx) * (1 - tz))
	if tx > 0 then
		addOld(d, p, a + 1, tx * (1 - tz))
	end
	if tz > 0 then
		addOld(d, p, a + n, (1 - tx) * tz)
		if tx > 0 then
			addOld(d, p, a + n + 1, tx * tz)
		end
	end
	return true
end

local function owns(L: number): boolean
	if count <= 1 then
		return true
	end
	-- a multiplicative hash, high bits: neighbours land on different shares, and each share gets
	-- about the same number of points in every ring
	return (L * 2654435761) % 4294967296 // 65536 % count + 1 == index
end

-- This share's vertices, sorted by what moves them (the waves in force decide which can move).
local function refreshLists(d: Data)
	table.clear(near)
	table.clear(far)
	table.clear(idle)
	table.clear(dryIdle)
	table.clear(drawnFrame)
	local fine = 1 / (3 * d.LodCell) - 1e-9
	for v, inv in d.Inv do
		if not d.Bones[v] or not owns(d.Lattice[v]) then
			continue
		end
		if Waves.MaxLength * inv > 1 then
			table.insert(if inv >= fine then near else far, v)
		else
			table.insert(idle, v)
		end
	end
	placeIdle = true
end

--[=[
	@within Draw
	Takes over a new build: the whole mesh's data, and which share of it this copy draws.
]=]
function Draw.Load(d: Data, share: number, shares: number)
	data, index, count = d, share, shares
	local points = d.N * d.N
	drawnCF, drawnFrame, drawnY = table.create(points), table.create(points), table.create(points)
	morphOff = table.create(#d.X * VALUES)
	table.clear(dampOf)
	table.clear(foamDamp)
	table.clear(foamKeys)
	table.clear(foamAlphas)
	table.clear(foamMine)
	table.clear(filmMine)
	for f, L in d.FoamLattice do
		if owns(L) then
			table.insert(foamMine, f)
		end
	end
	for j, L in d.FilmLattice do
		if owns(L) then
			table.insert(filmMine, j)
		end
	end
	seenVersion = Waves.Version
	refreshLists(d)
end

--[=[
	@within Draw
	Forgets the build (the Renderer destroyed it).
]=]
function Draw.Unload()
	data = nil
end

local frameCopy = {} :: Frame
--[=[
	@within Draw
	The frame the Renderer published, as a plain table (reused).
]=]
function Draw.ReadFrame(published: SharedTable): Frame
	for _, key in FRAME_KEYS do
		(frameCopy :: any)[key] = published[key]
	end
	return frameCopy
end

-- the obstacle damping of this share's vertices, for the mesh centred at (ox, oz)
local function refreshStatic(d: Data, ox: number, oz: number, radius: number)
	table.clear(dampOf)
	table.clear(foamDamp)
	obstacles = Waves.ObstaclesNear(ox, oz, radius * 1.5)
	if #obstacles == 0 then
		return
	end
	for _, list in { near, far } do
		for _, v in list do
			local damp = Waves.Damp(obstacles, ox + d.X[v], oz + d.Z[v])
			if damp < 1 then
				dampOf[v] = damp
			end
		end
	end
	for _, f in foamMine do
		local damp = Waves.Damp(obstacles, ox + d.FoamX[f], oz + d.FoamZ[f])
		if damp < 1 then
			foamDamp[f] = damp
		end
	end
end

local function write(bone: Bone, cf: CFrame)
	outCount += 1
	outBones[outCount], outCF[outCount] = bone, cf
end

--[=[
	@within Draw
	The maths of one update for this share: safe in parallel (it writes nothing). Returns false when
	there is nothing to draw (no build, or the frame is another build's), else how many vertices it
	updated.
]=]
function Draw.Step(p: Frame): number?
	local d = data
	if not d or p.Build ~= d.Build then
		return nil
	end
	if Waves.Version ~= seenVersion then
		seenVersion = Waves.Version
		refreshLists(d) -- wavelengths may have changed which vertices can move
	end
	outCount, posCount, colCount = 0, 0, 0
	recentre = if p.Moved and index == 1 then CFrame.new(p.Ox, 0, p.Oz) else nil
	recentreStatic = if recentre then CFrame.new(p.Ox, p.SeaLevel, p.Oz) else nil
	flatSea, shading = p.Flat, p.Shading
	local frame, ox, oz, seaLevel = p.Frame, p.Ox, p.Oz, p.SeaLevel
	local fx, fy, fz = p.Fx, p.Fy, p.Fz
	local rX, rY, rZ, uX, uY, uZ, kX, kY, kZ = p.RX, p.RY, p.RZ, p.UX, p.UY, p.UZ, p.KX, p.KY, p.KZ
	local tanH, tanV, secH, secV = p.TanH, p.TanV, p.SecH, p.SecV
	local lodCell = d.LodCell
	if p.Refresh then
		refreshStatic(d, ox, oz, p.Radius)
	end
	gZones = Waves.ZonesNear(ox, oz, p.Radius * 1.5)
	gNow = p.Now
	gCount = Waves.Gather(NO_ZONES, ox, oz, p.Now) -- the global weather's layers
	blendLook(gCount)
	gGlobalLoaded = true

	-- the dry boxes where their parts are this frame, those the water line crosses (a room wholly
	-- under the surface, or a deck wholly above the waves, leaves it alone)
	Regions.Sync()
	table.clear(dryNow)
	for _, box in Regions.Near(ox, oz, p.Radius * 1.5) do
		if box.Top > seaLevel and box.Bottom < seaLevel + Waves.MaxAmp then
			table.insert(dryNow, box)
		end
	end
	local cutting = #dryNow > 0
	local outline = if cutting then Regions.Outline(dryNow, seaLevel) else nil

	-- A point is on screen when it is in front of the camera and inside the view's four sides, each
	-- moved out by the point's margin: two of its cells (its triangles) and twice the tallest crest.
	local slack = 2 * Waves.MaxAmp + OFFSCREEN_MARGIN
	local function onScreen(wx: number, wz: number, cell: number): boolean
		local px, py, pz = wx - fx, seaLevel - fy, wz - fz
		local r = 2 * cell + slack
		local depth = px * kX + py * kY + pz * kZ
		if depth < -r then
			return false
		end
		local sx = px * rX + py * rY + pz * rZ
		if math.abs(sx) > depth * tanH + r * secH then
			return false
		end
		local sy = px * uX + py * uY + pz * uZ
		return math.abs(sy) <= depth * tanV + r * secV
	end

	local bones, baseX, baseZ, invSpacing, latticeOf = d.Bones, d.X, d.Z, d.Inv, d.Lattice
	local rest = CFrame.new(ox, 0, oz)
	if p.Moved or placeIdle then
		placeIdle = false
		for _, v in idle do
			write(bones[v], rest)
		end
	end

	local moved, morph, easing = p.Moved, p.Morph, p.Easing
	local updated = 0
	for pass = 1, if p.FarPass then 2 else 1 do
		local list: { number } = if pass == 1 then near else far
		for _, v in list do
			local L = latticeOf[v]
			if drawnFrame[L] == frame then -- the same point in the neighbouring tile, drawn already
				write(bones[v], drawnCF[L])
				continue
			end
			local wx, wz = ox + baseX[v], oz + baseZ[v]
			local cell = 1 / (3 * invSpacing[v])
			-- off screen: kept alive at a low rate for when the camera turns, a share of them each
			-- frame (by lattice point, so a shared point's copies agree), never all on one frame
			if not moved and (L + frame) % OFFSCREEN_EVERY ~= 0 and not onScreen(wx, wz, cell) then
				continue
			end
			updated += 1
			local dx, dy, dz, gx, gz, sxx, sxz, szz = sample(d, p, wx, wz, dampOf[v])
			local o = (v - 1) * VALUES
			if moved then -- re-sampled here: start from the old surface
				if morph and oldSurface(d, p, v) then
					morphOff[o + 1], morphOff[o + 2], morphOff[o + 3] = o1 - dx, o2 - dy, o3 - dz
					morphOff[o + 4], morphOff[o + 5], morphOff[o + 6] = o4 - gx, o5 - gz, o6 - sxx
					morphOff[o + 7], morphOff[o + 8] = o7 - sxz, o8 - szz
				else
					morphOff[o + 1] = nil
				end
			end
			if easing > 0 and morphOff[o + 1] then
				local e = easing
				dx, dy, dz = dx + morphOff[o + 1] * e, dy + morphOff[o + 2] * e, dz + morphOff[o + 3] * e
				gx, gz = gx + morphOff[o + 4] * e, gz + morphOff[o + 5] * e
				sxx, sxz, szz = sxx + morphOff[o + 6] * e, sxz + morphOff[o + 7] * e, szz + morphOff[o + 8] * e
			end
			drawnY[L] = dy
			if cutting and cell <= CUT_CELLS * lodCell then -- cut out of the dry boxes where they are now
				local cx, cy, cz = Regions.Cut(outline :: Regions.Outline, wx + dx, seaLevel + dy, wz + dz, cell)
				dx, dy, dz = cx - wx, cy - seaLevel, cz - wz
			end
			local cf = boneCFrame(ox + dx, dy, oz + dz, 1, gx, gz, sxx, sxz, szz)
			drawnCF[L], drawnFrame[L] = cf, frame
			write(bones[v], cf)
		end
	end

	-- vertices no wave moves still give way to a dry box, and go back to rest once it has passed
	if cutting or next(dryIdle) then
		for _, v in idle do
			local wx, wz = ox + baseX[v], oz + baseZ[v]
			local cx, cy, cz = wx, seaLevel, wz
			local cell = 1 / (3 * invSpacing[v])
			if cutting and cell <= CUT_CELLS * lodCell then
				cx, cy, cz = Regions.Cut(outline :: Regions.Outline, wx, seaLevel, wz, cell)
			end
			local L = latticeOf[v]
			if cx ~= wx or cy ~= seaLevel or cz ~= wz then
				dryIdle[v] = true
				local cf = CFrame.new(ox + cx - wx, cy - seaLevel, oz + cz - wz)
				drawnCF[L], drawnFrame[L] = cf, frame
				write(bones[v], cf)
			elseif dryIdle[v] then
				dryIdle[v] = nil
				drawnFrame[L] = nil
				write(bones[v], rest)
			end
		end
	end

	-- Foam and film ride the base lattice points under them: each takes the bone CFrame drawn there
	-- this frame (waves, damping, dry cut and all), and skips a point the base skipped (off screen).
	-- A point no wave moves (never drawn) rests at the re-centre offset. The foam's positions are
	-- written outright (plain mesh); its alpha and colour only on colour passes.
	local clamp, floor = math.clamp, math.floor
	if d.FoamMesh then
		local night = p.Night
		local nightKey = floor(night * 100) * 262144
		local sameLayers = #gZones == 0
		local foamFadeFrom, foamFadeTo = d.FoamFadeFrom, d.FoamFadeTo
		for _, f in foamMine do
			local L = d.FoamLattice[f]
			local seen = drawnFrame[L]
			if seen and seen ~= frame then
				continue
			end
			local position = (if seen then drawnCF[L] else rest).Position
			local lx, lz = d.FoamX[f], d.FoamZ[f]
			posCount += 1
			posIds[posCount], posValues[posCount] =
				d.FoamIds[f], Vector3.new(lx + position.X, position.Y, lz + position.Z)
			if not p.ColorPass then
				continue
			end
			local wx, wz = ox + lx, oz + lz
			gatherAt(wx, wz)
			local dy = if seen then drawnY[L] else 0 -- the wave height there, before the dry cut
			local shore = 0 -- 0..1 how much this point is in an obstacle's calming ring
			local damp = foamDamp[f]
			if damp and damp > 0 then
				-- peaks halfway across the ring (the "breaking" line), and only where a crest of the
				-- incoming wave is passing: the wash moves with the waves instead of sitting there
				shore = damp * (1 - damp) * 4 * clamp(2 * dy / damp / lookMaxAmp, 0, 1)
			end
			local foam = clamp((dy / lookMaxAmp - lookFoamStart) / math.max(lookFoamFull - lookFoamStart, 1e-3), 0, 1)
			foam = math.max(foam, shore * 0.6) -- wash against obstacles
			-- fades out toward the lattice's edge, measured from the camera so it never jumps
			local edge = clamp(
				(math.max(math.abs(wx - fx), math.abs(wz - fz)) - foamFadeFrom) / (foamFadeTo - foamFadeFrom),
				0,
				1
			)
			local fade = 1 - edge * edge * (3 - 2 * edge)
			-- quantised to 64 steps and only written when the step changes: the mesh upload is the
			-- expensive part, and most frames nothing here changed
			local key = nightKey
				+ floor(foam * 63)
				+ 64 * floor(fade * 63)
				+ (if sameLayers then 0 else 4096 * floor(lookFoamOpacity * 63))
			if key ~= foamKeys[f] then
				foamKeys[f] = key
				local alpha = (lookWebOpacity + (lookFoamOpacity - lookWebOpacity) * foam) * fade
				colCount += 1
				colIds[colCount] = d.FoamColorIds[f]
				colValues[colCount] = Color3.new(foamR * night, foamG * night, foamB * night)
				colAlphas[colCount] = if alpha ~= foamAlphas[f] then alpha else -1
				foamAlphas[f] = alpha
			end
		end
	end
	-- the film: the water's own bone CFrames on its own bones (nothing is written to its mesh)
	for _, j in filmMine do
		local L = d.FilmLattice[j]
		local seen = drawnFrame[L]
		if seen and seen ~= frame then
			continue
		end
		write(d.FilmBones[j], if seen then drawnCF[L] else rest)
	end
	return updated
end

--[=[
	@within Draw
	The writes of the last Step: serial only (Bone.Transform and EditableMesh can't be written in
	parallel).
]=]
function Draw.Write()
	local d = data
	if not d then
		return
	end
	for i = 1, outCount do
		outBones[i].Transform = outCF[i]
	end
	local fm = d.FoamMesh
	if fm then
		for i = 1, posCount do
			fm:SetPosition(posIds[i], posValues[i])
		end
		for i = 1, colCount do
			fm:SetColor(colIds[i], colValues[i])
			if colAlphas[i] >= 0 then
				fm:SetColorAlpha(colIds[i], colAlphas[i])
			end
		end
	end
	local offset = recentre
	if offset then -- the roots and the static mesh re-centre with the bones, in the same writes
		for _, root in d.Roots do
			root.Transform = offset
		end
		if d.Static and recentreStatic then
			d.Static.CFrame = recentreStatic
		end
	end
end

--[=[
	@within Draw
	World Y of the surface as drawn at (x, z) (see Renderer): the wave sum at spacing `inv`, the
	weather layers there and obstacles, inverted like Waves.Height so the sideways shove is
	accounted for. Gathers its own layers: call it before Step, not during.
]=]
function Draw.Height(x: number, z: number, inv: number): number
	local now = workspace:GetServerTimeNow()
	local t = Waves.Time()
	local zones = Waves.ZonesNear(x, z, 1)
	local nearby = Waves.ObstaclesNear(x, z, 1)
	local damp = if #nearby > 0 then Waves.Damp(nearby, x, z) else 1
	flatSea = false
	gCount = Waves.Gather(zones, x, z, now)
	local px, pz, y = x, z, 0
	for _ = 1, 3 do
		local dx, dy, dz = waveAt(px, pz, inv, t)
		px, pz, y = x - dx * damp, z - dz * damp, dy * damp
	end
	return Waves.SeaLevel + y
end

--[=[
	@within Draw
	The water's colour from the global weather: halfway between its deep and shallow colours.
	Gathers its own layers: call it before Step, not during.
]=]
function Draw.WaterColour(now: number): (number, number, number)
	blendLook(Waves.Gather(NO_ZONES, 0, 0, now))
	return (deepR + shallowR) / 2, (deepG + shallowG) / 2, (deepB + shallowB) / 2
end

return Draw

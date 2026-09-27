--!native
--!optimize 2
--[[
	Client-only. One EditableMesh that follows the camera = infinite ocean in every direction.

	The waves are BONES, not vertex writes. Any write to an EditableMesh (one vertex or all of
	them) makes the engine re-process the whole mesh that frame: ~2.5 us per vertex, ~15 ms for a
	6k-vertex sea, every frame. A skinned mesh costs nothing to move: every animated vertex is
	bound to its own Bone, and the frame writes Bone.Transform (an offset in the part's space).
	The engine cost is then linear in the bone count (~0.7 us per bone) and independent of the
	vertex count, so the horizon skirt and the static outer ring are free.

	The skinned geometry is TILED. Whenever mesh assets load into workspace (streaming a region
	in or out, cloning MeshParts) the engine rebuilds every skinned mesh at a cost of about
	vertices x bones per mesh: one 6k-vertex / 2.5k-bone sea stalls ~900 ms on every stream-in
	("the game freezes entering a new area"); four 625-vertex / 625-bone parts cost nothing
	measurable (measured: ~20-25 ms per million vertices x bones in one mesh). So the animated
	lattice is cut into blocks with the camera at a block CORNER: the bones land in exactly four
	tiles, and every vertex no wave can reach (the outer ring, the horizon skirt) lives in ONE
	plain mesh with no bones at all. Out along the axes the lattice is fine one way and coarse the
	other; only a coarse subset of those points has a bone, the rest ride two of them blended, so
	~3k bones carry the waves to the edge of the animated area (1-2k studs) in 4 modest tiles. Tiles share their border vertices (duplicated,
	same rest position, same displacement), so there are no cracks. All of it sits under a Model
	named OceanSurface that carries the stats attributes.

	Budget: a client may hold only ~8 EditableMesh / EditableImage objects, whatever their size.
	4 tiles + static + foam + film = 7 leaves one for the foam's animated image; SurfaceDetail
	Ripples adds two more. When that is refused the build steps down: no film, then no foam (and
	no ripples), then a single tile.

	LOD: the grid is uniform (CellSize) for InnerCells around the camera, then every cell outward
	is Growth x bigger up to a sixth of the longest wavelength, then the horizon skirt stretches
	to RenderDistance. Each wave is faded out on
	vertices whose local spacing can't resolve its wavelength (< 6 cells per wave -> fading,
	< 3 -> gone), so the distance never aliases/shimmers. Vertices no wave can reach are static
	and get no bone at all.

	The mesh re-centres by the texture tile (a whole number of fine cells, so nothing visibly
	jumps) and the tiled textures stay put in the world without a UV write. The skinned parts
	never move: the re-centre offset rides the bones (each tile's Root bone for its unbudgeted
	vertices), because a big move of a big skinned part costs the engine ~700 ms. The plain static
	mesh, having no bones, moves by its CFrame.

	Meshes cap at 2048 studs only at creation, so we create it shrunk and move the verts after.

	Look: three parts.
	  base: the whole lattice, flat SmoothPlastic in the water's colour (Part.Color: the vertex
	        colours are white, so the tint and the night darkening never touch the mesh). Lit, and
	        shaded by its bones' ROTATIONS: skinning turns a vertex's normal by its bone's rotation,
	        never by its offset, so every bone is also turned onto the displaced surface's normal
	        (see boneCFrame). Optionally a SurfaceAppearance on top with ripples lit per pixel
	        (SurfaceDetail.luau).
	  foam: a coarse near-camera lattice (2 x CellSize, InnerCells wide) with the animated
	        foam-ring texture; per-vertex ALPHA is the foam amount. Its alpha has to be written,
	        and a write to a SKINNED mesh is ~6x the cost of one to a plain mesh, so this one is
	        NOT skinned: it is its own small plain mesh whose 400-odd positions and alphas are
	        written outright (about 1 ms), never the base.
	  film: the same lattice, skinned, a translucent skin in the water's own colour at
	        FilmOpacity, so anything crossing the surface gets a clear waterline.
	Nothing writes to a skinned mesh after it is built: the textures tile by a multiple of the
	cell and the mesh re-centres by that tile, so the UVs never need to move either.
	Vertex alpha is only honoured on parts with Transparency > 0, hence FOAM_TRANSPARENCY. The base
	takes WaterTransparency (0, opaque, in every preset); see-through, a near crest still hides the
	water behind it.
	Lit = false draws the base as Neon: Roblox has no other way to keep shadows and highlights off it.

	Weather: with no zone near the camera every vertex shares the same 1-2 layers (fast path);
	otherwise layers are gathered per vertex so zones cross-fade in space. See Waves.luau.
]]
local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Regions = require(script.Parent.Regions)
local Settings = require(script.Parent.Settings)
local SurfaceDetail = require(script.Parent.SurfaceDetail)
local SurfaceTexture = require(script.Parent.SurfaceTexture)
local Waves = require(script.Parent.Waves)

local Renderer = {}
Renderer.Stats =
	{ Vertices = 0, Active = 0, Triangles = 0, UpdateMs = 0, Layers = 0, Bones = 0, Hitches = 0, Tiles = 0 }

local BIND_NAME = "OceanSurface"
local PLACEHOLDER_TAG = "OceanPlaceholder" -- the plugin's flat stand-in water: hidden while the real sea runs
local FOAM_MATERIAL = Enum.Material.SmoothPlastic
local DEFAULT_MATERIAL = Enum.Material.SmoothPlastic
local TILE_CELLS = 4 -- the textures repeat every this many fine cells (and the mesh re-centres by that)
local FOAM_TRANSPARENCY = 0.02
local FOAM_LIFT = 0.2 -- studs above the base, to avoid z-fighting; the film sits above the foam
local FILM_LIFT = 0.35
local STATIC_REFRESH = 0.25 -- s between re-evaluations of the per-vertex obstacle / dry-region fields
local DRY_SINK = 0.5 -- studs the surface runs under a dry region's bottom (no z-fighting with its floor)
-- Not Neon: emissive glow ignores transparency and washes the whole near field white at any opacity.
local FILM_MATERIAL = Enum.Material.SmoothPlastic
local UNDERWATER_GUI = "OceanUnderwater" -- the module's own full-screen tint frame, shown while the camera is under
local MAX_CELLS_PER_SIDE = 49
local BEHIND_MARGIN = 48 -- studs behind the camera plane before a vertex counts as "behind"
local BEHIND_EVERY = 4 -- behind-camera vertices update every Nth frame (they still exist for turns)
-- bones cost ~0.7 us each per frame whether or not they moved, and past ~4k a mesh
-- gets pathological; the outermost animated vertices (long swells 400+ studs out) lose theirs first.
local MAX_BONES = 3400

-- Adaptive quality. A device's EditableMesh memory budget (tight on phones, generous in Studio)
-- decides how much of the sea it can hold, and its frame time decides how much it can animate.
-- `budgetLevel` is the rung being shown: 0 is everything the settings ask for, each rung drops
-- something, and the last is no mesh at all, a flat slab.
--   0 full | 1 no film | 2 no foam | 3 one tile | 4 one tile, half the lattice
--   5 one tile, a quarter of the lattice | 6 flat, no EditableMesh
-- When a build is refused the sea falls to the flat slab at once, then climbs a rung at a time
-- from the bottom. A refused climb doubles the wait before the next try; a slow frame time steps
-- down a rung. So it settles on the best rung the device holds, and keeps probing upward slowly.
local FLAT_LEVEL = 6
local LEVEL_NAMES = { [0] = "full", "no film", "no foam", "one tile", "half lattice", "quarter lattice", "flat" }
local CLIMB_FIRST = 2 -- s after falling to flat before the first rung is tried
local CLIMB_MIN, CLIMB_MAX = 6, 180 -- s between climbs: grows when one is refused
local SLOW_MS = 7 -- a mesh update costing more than this for SLOW_FOR seconds steps down a rung
local SLOW_FOR = 3
local budgetLevel = 0
local climbDelay = CLIMB_MIN
local nextClimb = math.huge -- os.clock() of the next attempt at a better rung
local slowSince: number? = nil
local building = false

local function boneBudget(): number
	return if budgetLevel >= 5 then 300 elseif budgetLevel >= 4 then 900 elseif budgetLevel >= 3 then 1600 else MAX_BONES
end
-- Lattice cells per tile side, at least BLOCK and as many as the bones reach: the camera sits at a
-- block corner, so the bones land in 4 tiles and everything past them is the static mesh.
local BLOCK = 32
local block = BLOCK

-- Quality tiers, applied on top of the Advanced mesh settings. Bone count (= animated vertices)
-- is what the frame cost scales with, so Fast quarters it.
local QUALITY = {
	Fast = {
		CellScale = 2,
		InnerScale = 0.5,
		OuterScale = 0.5,
		Film = false,
		SmoothFoam = false,
		ColorEvery = 4,
		FarEvery = 3,
	},
	Regular = {
		CellScale = 1.25,
		InnerScale = 0.8,
		OuterScale = 0.8,
		Film = true,
		SmoothFoam = true,
		ColorEvery = 2,
		FarEvery = 2,
	},
	Realistic = {
		CellScale = 1,
		InnerScale = 1,
		OuterScale = 1,
		Film = true,
		SmoothFoam = true,
		ColorEvery = 1,
		FarEvery = 1,
	},
}
local quality = QUALITY.Regular
local qCell, qInner, qOuter = 8, 24, 25 -- the tier-scaled mesh settings in force
local N = Settings.WAVE_COUNT
local NO_ZONES = {}

local container: Model? = nil -- "OceanSurface": every part of the sea, and the stats attributes
local tileParts: { MeshPart } = {}
local tileMeshes: { EditableMesh } = {}
local roots: { Bone } = {} -- per tile: the bone its unbudgeted vertices ride; carries the re-centre
local staticPart: MeshPart? = nil -- the plain, bone-free mesh: outer ring + horizon skirt
local staticMesh: EditableMesh? = nil
local foamMesh: EditableMesh? = nil
local foamPart: MeshPart? = nil
local filmParts: { MeshPart } = {}
local filmMeshes: { EditableMesh } = {}
local parent: Instance = workspace
local buildToken = 0
local running = false
local connection: Settings.Connection? = nil
local placeholderAdded: RBXScriptConnection? = nil

-- per-vertex flat arrays: one entry per TILE vertex (a lattice point shared by two tiles is in
-- here twice), index v. The static mesh's vertices are not in here: nothing ever moves them.
local baseX: { number } = {}
local baseZ: { number } = {}
local invSpacing: { number } = {} -- 1 / (3 x largest adjacent cell): wavelength x this - 1 = LOD weight
local bones: { Bone? } = {} -- vertex -> its bone (animated vertices only)
local hasSkin: { boolean? } = {} -- vertex -> true when its tile mesh has a skin bone for it (the nearest MAX_BONES)
local partOf: { MeshPart } = {} -- vertex -> its tile part (the bone's parent)
local localOf: { number } = {} -- vertex -> its index inside its tile (= the skin bone's name)
local latticeOf: { number } = {} -- vertex -> lattice point index (zi - 1) * gridN + xi
local near: { number } = {} -- full-detail vertices some wave can move: updated every frame
local far: { number } = {} -- LOD-ring vertices: updated every other frame, all together
local idle: { number } = {} -- skinned vertices no current wave can move: placed on re-centre only
local gridN = 0
-- the foam lattice: FINE spacing over the inner half of the full-detail area (coarser and the base
-- pokes through between its vertices), one plain mesh. Index f.
local foamX: { number } = {}
local foamZ: { number } = {}
local foamIds: { number } = {}
local foamColorIds: { number } = {}
-- the film: the foam's lattice (the base's own vertices over the inner half), skinned. Index j.
local filmBones: { Bone } = {}
local filmX: { number } = {}
local filmZ: { number } = {}
local lastSeaLevel = math.huge -- the parts' height last written
local foamAlphas: { number } = {} -- last alpha written per foam vertex
local foamKeys: { number } = {} -- quantised colour last written per foam vertex
local foamDamp: { number? } = {} -- foam vertex -> obstacle damp, nil = open water
local filmDamp: { number? } = {} -- film bone -> obstacle damp, nil = open water
-- Dry regions sink the mesh: every vertex inside a box drops to just under the box bottom, and the
-- ring of them next to the outside is also pushed out to the wall, so the surface dives from the
-- water line down the outside of the wall and runs flat underneath - no hole, no water indoors.
-- Re-evaluated on re-centre and every STATIC_REFRESH.
local pinned: { { number }? } = {} -- vertex -> { dx, dz, y } world offset to the wall (0 when deep inside), sunk height
-- Obstacle damping and "could a wave shove me into a dry box" depend only on the vertex's rest
-- position, so they are fields refreshed with the pins, not per frame.
local dampOf: { number? } = {} -- vertex -> damp factor, nil = open water
local nearDry: { boolean? } = {} -- vertex -> true when within shove reach of a dry box footprint
local dryNear: { Regions.Box } = {} -- the boxes near the mesh, for those vertices
local foamPin: { { number }? } = {} -- foam vertex inside a dry box -> { dx, dz, y } like `pinned`
local filmPin: { { number }? } = {} -- film bone inside a dry box, the same
local staticTimer = 0
local staticDone = false -- StaticWaves: one full position pass has been written since the last change
local coloredOnce = false -- DynamicColors off: one colour pass has been written
local nextUpdate = 0 -- os.clock() of the next mesh update (UpdateRate throttle)
local frame = 0
local lastOx, lastOz = math.huge, math.huge
local tile = 32 -- studs per texture repeat: TILE_CELLS fine cells
local snap = 32 -- studs the mesh re-centres by: the texture tile, so the textures stay put in the world
-- Continuous LOD: the fade of each wave depends on distance from the TRUE camera position, via
-- the grid's own spacing law spacing(d) = min(cell + (d - innerRadius) * (growth - 1) / growth, cap),
-- not on which ring a vertex happens to sit in, so re-centring the mesh never changes a wave's weight.
-- The cap: outer cells stop growing at a sixth of the longest wavelength (the most the fade draws
-- at full height), so the long swell reaches the edge of the animated area at full height instead
-- of fading out a few rings past the inner one.
local lodCell, lodInner, lodSlope, lodCap = 8, 0, 0, math.huge
local animatedRadius = 0
-- The skin set is the nearest MAX_BONES lattice points, a disc; past its edge vertices rest flat on
-- Root. Every wave fades to nothing over the outer part of that disc, so the edge never shows. The
-- fade (and the foam's) is measured from the camera, not the mesh centre, which jumps a tile at a
-- time: a ring measured from it would jump with it. It ends a re-centre step short of the disc
-- (the camera is at most that far from the centre), so it is complete wherever the camera is.
local skinFadeFrom, skinFadeTo = 0, 1 -- studs from the camera
local foamFadeFrom, foamFadeTo = 0, 1 -- studs from the camera, per axis (the foam lattice is square)
-- A re-centre moves every vertex a tile, so past the uniform inner cells each one samples the waves
-- somewhere new and a crest drawn on the old samples would pop to the new ones. Instead each vertex
-- starts where the old surface was drawn at its new place (the old lattice, interpolated) and eases
-- to its own sample over MORPH_TIME.
local MORPH_TIME = 0.35
local VALUES = 8 -- per drawn point: displacement x, y, z, then the five normal sums
local drawn: { number } = {} -- lattice point -> what was last drawn there (VALUES each, after fades)
local morphFrom: { number } = {} -- vertex -> the old surface at its new place, on the re-centre frame
local morphOff: { number } = {} -- vertex -> old surface minus own sample, easing to 0
local morphStart = -math.huge
local gridCoords: { number } = {} -- the lattice axis in force
local skinnedAt: { boolean? } = {} -- lattice point -> it has a bone
local blendOf: { [number]: { number } } = {} -- lattice point -> the two bone points it rides, and A's weight
local seenVersion = -1
local seenNight = -1

-- blended look for the current vertex / frame (flat, to stay allocation-free in the hot loop)
local lookMaxAmp, lookFoamStart, lookFoamFull, lookFoamOpacity, lookWebOpacity = 1, 0, 1, 1, 0
local deepR, deepG, deepB, shallowR, shallowG, shallowB, foamR, foamG, foamB = 0, 0, 0, 0, 0, 0, 1, 1, 1

local function applyQuality()
	quality = QUALITY[Settings.Get("Quality")] or QUALITY.Regular
	qCell = Settings.Get("CellSize") * quality.CellScale
	local inner = math.floor(Settings.Get("InnerCells") * quality.InnerScale)
	local outer = math.floor(Settings.Get("OuterCells") * quality.OuterScale)
	-- EditableMesh caps at 20k triangles = 100x100 quads = 50 cells per side, one of which is the skirt.
	-- Single mesh; split into a few MeshParts if you ever need more than 49 cells a side.
	qInner = math.clamp(inner, 2, MAX_CELLS_PER_SIDE - 2)
	if qInner % 2 == 1 then
		qInner += 1 -- the foam lattice is every other fine vertex: keep the inner area an even number of cells
	end
	qOuter = math.clamp(outer, 1, MAX_CELLS_PER_SIDE - qInner)
	if budgetLevel >= 4 then
		-- the same reach with a half (or a quarter) of the cells per side: a fourth (a sixteenth) of the mesh
		local shrink = if budgetLevel >= 5 then 4 else 2
		-- coarser cells, but never so coarse that the longest wave stops moving the mesh
		qCell = math.min(qCell * shrink, math.max(qCell, Waves.MaxLength / 6))
		qInner = math.max(2, (qInner // shrink) // 2 * 2)
		qOuter = math.max(1, qOuter // shrink)
	end
	tile = qCell * TILE_CELLS
	snap = tile
	SurfaceTexture.SetSmooth(quality.SmoothFoam)
	SurfaceDetail.SetSmooth(quality.SmoothFoam)
end

local function buildAxis(): ({ number }, { number })
	local cell, inner, outer = qCell, qInner, qOuter
	local growth = Settings.Get("Growth")
	local cap = lodCap

	local half = { 0 } -- coordinates from the centre outward
	local sizes = {} -- sizes[i] = cell between half[i] and half[i + 1]
	local size = cell
	-- the animated area stops at a quarter of RenderDistance however large Growth is: past that
	-- the cells left share what remains evenly
	local reach = Settings.Get("RenderDistance") / 4
	for i = 1, inner + outer do
		if i > inner then
			size = math.min(size * growth, math.max((reach - half[i]) / (inner + outer - i + 1), cell), cap)
		end
		sizes[i] = size
		half[i + 1] = half[i] + size
	end
	-- horizon skirt: one giant cell, flat (no wave survives that spacing). Always at least 4x the
	-- animated area, whatever RenderDistance says, so the skirt is never a thin animated rim.
	local horizon = math.max(Settings.Get("RenderDistance"), half[#half] * 4)
	table.insert(sizes, horizon - half[#half])
	table.insert(half, horizon)

	local coords, space = {}, {}
	for i = #half, 2, -1 do
		table.insert(coords, -half[i])
		table.insert(space, sizes[i] or sizes[i - 1]) -- the larger (outer) neighbour cell
	end
	table.insert(coords, 0)
	table.insert(space, sizes[1])
	for i = 2, #half do
		table.insert(coords, half[i])
		table.insert(space, sizes[i] or sizes[i - 1])
	end
	return coords, space
end

-- Blend the look of the first `count` gathered layers into the look* locals.
local function blendLook(count: number)
	local sets, weights = Waves.LayerSets, Waves.LayerWeights
	lookMaxAmp, lookFoamStart, lookFoamFull, lookFoamOpacity, lookWebOpacity = 0, 0, 0, 0, 0
	deepR, deepG, deepB, shallowR, shallowG, shallowB, foamR, foamG, foamB = 0, 0, 0, 0, 0, 0, 0, 0, 0
	for i = 1, count do
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

-- "123456" / "rbxassetid://..." -> Content, "" -> nil
local function contentFrom(id: string): Content?
	local trimmed = (id:match("^%s*(.-)%s*$") :: string) or ""
	if trimmed:match("^%d+$") then
		return Content.fromUri("rbxassetid://" .. trimmed)
	elseif trimmed:match("^rbx") then
		return Content.fromUri(trimmed)
	end
	return nil
end

-- Material and textures from the settings; cheap, so re-run on any Visuals change.
-- Every part of the water surface: the tiles and the static mesh.
local function surfaceParts(): { MeshPart }
	local list = table.clone(tileParts)
	if staticPart then
		table.insert(list, staticPart)
	end
	return list
end

-- Air and Water are terrain-only: a part cannot take them
local function partMaterials(): { Enum.Material }
	local items = {}
	for _, item in Enum.Material:GetEnumItems() do
		if item ~= Enum.Material.Air and item ~= Enum.Material.Water then
			table.insert(items, item)
		end
	end
	return items
end

-- WaterMaterial by name: an Enum.Material or a MaterialVariant in MaterialService (returned as the
-- second value with its base); an unknown name lands on the closest (prefix / substring), else the default.
local function materialFor(name: string): (Enum.Material, string)
	local wanted = tostring(name or ""):lower()
	for _, variant in game:GetService("MaterialService"):GetChildren() do
		if variant:IsA("MaterialVariant") and variant.Name:lower() == wanted then
			return variant.BaseMaterial, variant.Name
		end
	end
	local items = partMaterials()
	for _, item in items do
		if item.Name:lower() == wanted then
			return item, ""
		end
	end
	if wanted ~= "" then
		for _, item in items do
			if item.Name:lower():sub(1, #wanted) == wanted or item.Name:lower():find(wanted, 1, true) then
				return item, ""
			end
		end
	end
	return DEFAULT_MATERIAL, ""
end

local function applyLook()
	-- Roblox cannot keep shadows or highlights off a lit part: unlit means Neon, flat colour
	local material, variant = materialFor(Settings.Get("WaterMaterial"))
	local texture = contentFrom(Settings.Get("WaterTexture")) or Content.none
	for _, base in surfaceParts() do
		base.Material = if not Settings.Get("Lit") then Enum.Material.Neon else material
		base.MaterialVariant = if Settings.Get("Lit") then variant else ""
		base.Reflectance = if Settings.Get("Lit") then Settings.Get("Reflectance") else 0
		base.TextureContent = texture
		base.Transparency = Settings.Get("WaterTransparency")
	end
	local foam = foamPart
	if foam then
		local style = Settings.Get("FoamStyle")
		local image = if style == "Texture" then contentFrom(Settings.Get("FoamTexture")) else nil
		if style == "Animated" then
			foam.TextureContent = SurfaceTexture.Get()
		else
			SurfaceTexture.Stop() -- no flipbook to bake or play
			foam.TextureContent = image or Content.none -- Solid (or a blank texture id): plain colour
		end
	end
	-- ripples need the lit water, and go with the foam when the device's budget is tight
	local detail = if Settings.Get("Lit") and budgetLevel < 2 then Settings.Get("SurfaceDetail") else "None"
	SurfaceDetail.Apply(detail, surfaceParts())
end

-- 1 by day, NightBrightness once the sun is down. The ocean only READS the sky; it never sets it.
local Lighting = game:GetService("Lighting")

local function nightFactor(): number
	local sun = math.clamp((Lighting:GetSunDirection().Y + 0.1) / 0.35, 0, 1)
	local night = Settings.Get("NightBrightness")
	return night + (1 - night) * sun * sun * (3 - 2 * sun)
end

-- The water's colour is the PART colour (times the white vertex colours), so tinting and the night
-- darkening never touch the mesh. Far water: global weather, calm height.
local function recolour(night: number)
	if not container then
		return
	end
	blendLook(Waves.Gather(NO_ZONES, 0, 0, workspace:GetServerTimeNow()))
	local colour =
		Color3.new((deepR + shallowR) / 2 * night, (deepG + shallowG) / 2 * night, (deepB + shallowB) / 2 * night)
	for _, base in surfaceParts() do
		base.Color = colour
	end
	for _, film in filmParts do
		film.Color = colour -- the skin is the water's colour: no bright patch around the camera
	end
end

-- Which vertices any wave can still move (near: fine lattice, far: LOD ring). Every skinned vertex
-- keeps its Bone instance: without one it would draw where it was built, not where the mesh has
-- re-centred, and blended neighbours ride it. The ones no wave can move are `idle`: moved by the
-- re-centre only. The rule is per lattice point, so both copies of a shared border vertex agree.
local function refreshActive()
	if not container then
		return
	end
	table.clear(near)
	table.clear(far)
	table.clear(idle)
	animatedRadius = 0
	local fine = 1 / (3 * qCell) - 1e-9
	local active = 0
	for v = 1, #baseX do
		if not hasSkin[v] then
			continue
		end
		if not bones[v] then
			local bone = Instance.new("Bone")
			bone.Name = tostring(localOf[v])
			bone.Position = Vector3.new(baseX[v], 0, baseZ[v])
			bone.Parent = partOf[v]
			bones[v] = bone
		end
		-- a wave still moves this vertex if wavelength * invSpacing - 1 > 0
		if Waves.MaxLength * invSpacing[v] > 1 then
			active += 1
			if invSpacing[v] >= fine then
				table.insert(near, v)
			else
				table.insert(far, v)
			end
			animatedRadius = math.max(animatedRadius, math.abs(baseX[v]), math.abs(baseZ[v]))
		else
			table.insert(idle, v)
		end
	end
	lastOx, lastOz = math.huge, math.huge -- the next update places every bone, idle ones included
	Renderer.Stats.Active = active
	Renderer.Stats.Bones = #near + #far + #idle + #filmBones
	seenNight = -1 -- recolour
end

-- The plugin's flat placeholder water is hidden (locally) while the wave mesh runs, and left
-- showing when the sea is flat: then it IS the sea. Nothing else uses the modifier on it, so
-- showing is always back to 0: a slab hidden by an earlier run of this module (a reinstall, a
-- plugin reload) comes back too.
local function hidePlaceholders()
	for _, placeholder in CollectionService:GetTagged(PLACEHOLDER_TAG) do
		if placeholder:IsA("BasePart") then
			placeholder.LocalTransparencyModifier = 1 -- local only: the saved part is untouched
		end
	end
end

local function showPlaceholders()
	for _, placeholder in CollectionService:GetTagged(PLACEHOLDER_TAG) do
		if placeholder:IsA("BasePart") then
			placeholder.LocalTransparencyModifier = 0
		end
	end
end

local function destroyMesh()
	if container then
		container:Destroy()
	end
	for _, list in { tileMeshes, filmMeshes } do
		for _, em in list do
			em:Destroy()
		end
	end
	for _, em in { staticMesh, foamMesh } do
		if em then
			em:Destroy()
		end
	end
	container, staticPart, staticMesh, foamMesh, foamPart = nil, nil, nil, nil, nil
	table.clear(tileParts)
	table.clear(tileMeshes)
	table.clear(roots)
	table.clear(filmParts)
	table.clear(filmMeshes)
	table.clear(bones)
	table.clear(filmBones)
	table.clear(filmX)
	table.clear(filmZ)
	table.clear(partOf)
	table.clear(localOf)
	table.clear(latticeOf)
end

-- The block a lattice CELL (1 .. n - 1, spanning vertices c .. c + 1) belongs to. The centre
-- vertex m is a block corner, so the bone disc around the camera is split in four.
local pendingMeshes: { EditableMesh } = {} -- created by the build in progress, destroyed if it fails

local function blockOf(c: number, m: number): number
	if budgetLevel >= 3 then
		return 0 -- one tile for the whole lattice
	end
	return (c - m) // block
end

-- A mesh over a set of lattice cells: UVs tiled in world studs, an optional colour per vertex, and
-- a skin bone (named by the vertex's index in THIS mesh) on the lattice points in `skin` (all of
-- them when true, none when false; a table is indexed by lattice point). A skinned mesh drops any
-- vertex with no bone, so with a table the rest ride one "Root" bone. Vertices are emitted lazily,
-- so a tile (a rectangle of cells) and the static mesh (any set) share this. Returns the mesh, the
-- lattice point of each emitted vertex, the vertex ids, the colour ids, and the creation shrink
-- (< 1 when the mesh is wider than the 2048-stud creation cap; the caller restores the real
-- positions after CreateMeshPartAsync). `blend` (lattice point -> { point A, point B, weight of A })
-- binds a point with no bone of its own between two that have one, in this same mesh.
local function latticeMesh(
	coords: { number },
	cells: { number },
	n: number,
	withColors: boolean,
	skin: { boolean? } | boolean,
	blend: { [number]: { number } }?
): (EditableMesh, { number }, { number }, { number }, number)
	local em = AssetService:CreateEditableMesh()
	if not em then
		error("EditableMesh memory budget reached")
	end
	table.insert(pendingMeshes, em)
	local verts, vids, cids, uvs = {}, {}, {}, {}
	local emitted: { [number]: number } = {} -- lattice point -> emitted index
	local boneOf: { [number]: number } = {} -- emitted index -> its own skin bone
	local root = if typeof(skin) == "table"
		then em:AddBone({ Name = "Root", CFrame = CFrame.identity, Virtual = false })
		else nil
	local reach = 0
	for _, c in cells do
		local cx, cz = (c - 1) % (n - 1) + 1, (c - 1) // (n - 1) + 1
		reach = math.max(
			reach,
			math.abs(coords[cx]),
			math.abs(coords[cx + 1]),
			math.abs(coords[cz]),
			math.abs(coords[cz + 1])
		)
	end
	local shrink = math.min(1, 1000 / reach)
	local function vertex(xi: number, zi: number): number
		local L = (zi - 1) * n + xi
		local k = emitted[L]
		if k then
			return k
		end
		k = #verts + 1
		emitted[L] = k
		verts[k] = L
		local x, z = coords[xi], coords[zi]
		vids[k] = em:AddVertex(Vector3.new(x * shrink, 0, z * shrink))
		uvs[k] = em:AddUV(Vector2.new(x / tile, z / tile))
		if withColors then
			cids[k] = em:AddColor(Color3.new(1, 1, 1), 0)
		end
		if skin == true or (typeof(skin) == "table" and skin[L]) then
			local bid = em:AddBone({ Name = tostring(k), CFrame = CFrame.new(x, 0, z), Virtual = false })
			boneOf[k] = bid
			em:SetVertexBones(vids[k], { bid })
			em:SetVertexBoneWeights(vids[k], { 1 })
		elseif root then
			em:SetVertexBones(vids[k], { root })
			em:SetVertexBoneWeights(vids[k], { 1 })
		end
		return k
	end
	for _, c in cells do
		local cx, cz = (c - 1) % (n - 1) + 1, (c - 1) // (n - 1) + 1
		local a, b = vertex(cx, cz), vertex(cx + 1, cz)
		local cc, d = vertex(cx + 1, cz + 1), vertex(cx, cz + 1)
		for _, tri in { { a, cc, b }, { a, d, cc } } do
			local face = em:AddTriangle(vids[tri[1]], vids[tri[2]], vids[tri[3]])
			em:SetFaceUVs(face, { uvs[tri[1]], uvs[tri[2]], uvs[tri[3]] })
			if withColors then
				em:SetFaceColors(face, { cids[tri[1]], cids[tri[2]], cids[tri[3]] })
			end
		end
	end
	-- the blended points, now that every bone is in (they stay on Root if a partner is not)
	if blend then
		for k, L in verts do
			local pair = blend[L]
			local a, b = pair and emitted[pair[1]], pair and emitted[pair[2]]
			if a and b and boneOf[a] and boneOf[b] then
				em:SetVertexBones(vids[k], { boneOf[a], boneOf[b] })
				em:SetVertexBoneWeights(vids[k], { pair[3], 1 - pair[3] })
			end
		end
	end
	return em, verts, vids, cids, shrink
end

-- Cells of an n-vertex lattice grouped by block: key "kx,kz" -> cell list, in a stable order.
local function blocksOf(n: number): ({ string }, { [string]: { number } })
	local m = (n + 1) // 2
	local keys, cellsOf = {}, {}
	for cz = 1, n - 1 do
		for cx = 1, n - 1 do
			local key = `{blockOf(cx, m)},{blockOf(cz, m)}`
			local list = cellsOf[key]
			if not list then
				list = {}
				cellsOf[key] = list
				table.insert(keys, key)
			end
			table.insert(list, (cz - 1) * (n - 1) + cx)
		end
	end
	return keys, cellsOf
end

local function buildOnce(token: number)
	applyQuality()
	lodCap = math.max(qCell, Waves.MaxLength / 6)
	local coords, space = buildAxis()
	lodCell = qCell
	lodInner = qCell * qInner
	local growth = Settings.Get("Growth")
	lodSlope = (growth - 1) / growth
	local n = #coords
	local m = (n + 1) // 2 -- the centre vertex (coords[m] == 0)

	-- The lattice is rows x columns, so out along the axes one direction stays as fine as the inner
	-- square while the other is coarse, and the waves there are only drawn at the coarse spacing (the
	-- LOD fade). A bone on every point of those strips would spend most of the budget on nothing.
	-- Along the finer axis only coordinates about the coarse spacing apart (picked outward from the
	-- centre) get a bone; each point between rides the two either side of it, blended.
	local keptCache: { [number]: { boolean } } = {}
	local function keptAt(r: number): { boolean }
		local kept = keptCache[r]
		if not kept then
			kept = table.create(n, false)
			kept[m] = true
			for dir = -1, 1, 2 do
				local last, i = 0, m + dir
				while i >= 1 and i <= n do
					if math.abs(coords[i] - last) >= r * 0.75 then
						kept[i] = true
						last = coords[i]
					end
					i += dir
				end
			end
			keptCache[r] = kept
		end
		return kept
	end
	-- the finer axis at a point (1 = x, 2 = z, 0 = neither) and the coordinates kept along it
	local function fineAxis(xi: number, zi: number): (number, { boolean }?)
		local sx, sz = space[xi], space[zi]
		if sx < sz then
			return 1, keptAt(sz)
		elseif sz < sx then
			return 2, keptAt(sx)
		end
		return 0, nil
	end

	-- The skin set, per lattice point: the nearest bone-owning points some wave can move, until
	-- MAX_BONES is spent. The tiles are grown to hold all of them, so the only block borders they
	-- cross are the two centre lines; a point on one is in two (or four) tiles, a bone in each.
	local byDistance = {}
	for zi = 1, n do
		for xi = 1, n do
			local axis, kept = fineAxis(xi, zi)
			local owns = axis == 0 or (kept :: { boolean })[if axis == 1 then xi else zi]
			if owns and Waves.MaxLength > 3 * math.max(space[xi], space[zi]) then
				table.insert(byDistance, (zi - 1) * n + xi)
			end
		end
	end
	table.sort(byDistance, function(a, b)
		local ax, az = coords[(a - 1) % n + 1], coords[(a - 1) // n + 1]
		local bx, bz = coords[(b - 1) % n + 1], coords[(b - 1) // n + 1]
		return ax * ax + az * az < bx * bx + bz * bz
	end)
	local oneTile = budgetLevel >= 3
	local skinL: { boolean? } = {}
	local spent, skinReach = 0, 0
	for _, L in byDistance do
		local xi, zi = (L - 1) % n + 1, (L - 1) // n + 1
		local cost = if oneTile then 1 else (if xi == m then 2 else 1) * (if zi == m then 2 else 1)
		if spent + cost > boneBudget() then
			break
		end
		spent += cost
		skinL[L] = true
		skinReach = math.max(skinReach, math.sqrt(coords[xi] ^ 2 + coords[zi] ^ 2))
	end

	-- every other point between two skinned ones along its finer axis rides them, blended
	local blend: { [number]: { number } } = {}
	local lone = {} -- inside the skin with no pair to ride (near the diagonal): a bone of its own
	for zi = 1, n do
		for xi = 1, n do
			local L = (zi - 1) * n + xi
			local axis, kept = fineAxis(xi, zi)
			local i = if axis == 1 then xi else zi
			if
				skinL[L]
				or math.sqrt(coords[xi] ^ 2 + coords[zi] ^ 2) > skinReach
				or Waves.MaxLength <= 3 * math.max(space[xi], space[zi])
			then
				continue -- skinned already, or at rest like everything past the skin
			elseif axis == 0 or (kept :: { boolean })[i] then
				table.insert(lone, L)
				continue
			end
			local toward = if i > m then -1 else 1
			local a, b = i + toward, i - toward -- the kept coordinates either side
			while not (kept :: { boolean })[a] do
				a += toward
			end
			while b >= 1 and b <= n and not (kept :: { boolean })[b] do
				b -= toward
			end
			local La = if axis == 1 then (zi - 1) * n + a else (a - 1) * n + xi
			local Lb = if axis == 1 then (zi - 1) * n + b else (b - 1) * n + xi
			if b >= 1 and b <= n and skinL[La] and skinL[Lb] then
				blend[L] = { La, Lb, (coords[b] - coords[i]) / (coords[b] - coords[a]) }
			else
				table.insert(lone, L)
			end
		end
	end
	-- (a few, on top of the budget: without one they would sit flat between moving neighbours)
	local reach = 0 -- the farthest skinned point from the centre, in lattice steps
	for _, L in lone do
		skinL[L] = true
	end
	for L in skinL do
		reach = math.max(reach, math.abs((L - 1) % n + 1 - m), math.abs((L - 1) // n + 1 - m))
	end
	block = math.max(BLOCK, reach + 1)

	-- A block with any skinnable point is a tile; every other cell is static. A skinnable point is
	-- in every block that touches it, so the tile / static border is at rest on both sides.
	local keys, cellsOf = blocksOf(n)
	local tileKeys, staticCells = {}, {}
	for _, key in keys do
		local cells = cellsOf[key]
		local skinned = false
		for _, c in cells do
			local cx, cz = (c - 1) % (n - 1) + 1, (c - 1) // (n - 1) + 1
			if
				skinL[(cz - 1) * n + cx]
				or skinL[(cz - 1) * n + cx + 1]
				or skinL[cz * n + cx]
				or skinL[cz * n + cx + 1]
			then
				skinned = true
				break
			end
		end
		if skinned then
			table.insert(tileKeys, key)
		else
			for _, c in cells do
				table.insert(staticCells, c)
			end
		end
	end

	-- the meshes: tiles, the static rest, the foam, the film tiles
	local newTileMeshes, tileVerts, tileVids, tileShrink = {}, {}, {}, {}
	for i, key in tileKeys do
		newTileMeshes[i], tileVerts[i], tileVids[i], _, tileShrink[i] =
			latticeMesh(coords, cellsOf[key], n, false, skinL, blend)
	end
	local newStatic: EditableMesh?, staticVids, staticVerts, staticShrink = nil, {}, {}, 1
	if #staticCells > 0 then
		newStatic, staticVerts, staticVids, _, staticShrink = latticeMesh(coords, staticCells, n, false, false)
	end
	-- foam: fine spacing over the inner half (so the base never pokes through between its
	-- vertices), a plain mesh whose positions and alpha are written; none at all for FoamStyle None
	local fineHalf = {}
	for c = -lodInner / 2, lodInner / 2 + 1e-3, qCell do
		table.insert(fineHalf, c)
	end
	local fn = #fineHalf
	local fm: EditableMesh?, foamVerts, newFoamIds, foamColors = nil, {}, {}, {}
	if Settings.Get("FoamStyle") ~= "None" and budgetLevel < 2 then
		local foamBlockKeys, foamCells = blocksOf(fn)
		local allFoam = {}
		for _, key in foamBlockKeys do
			for _, c in foamCells[key] do
				table.insert(allFoam, c)
			end
		end
		fm, foamVerts, newFoamIds, foamColors = latticeMesh(fineHalf, allFoam, fn, true, false)
	end
	-- film: the foam's lattice, skinned. Its vertices are the base's own (same spacing, same
	-- places), so the water never pokes through it between two of them. One mesh: every mesh
	-- counts against the client's budget.
	local coarse, cn = fineHalf, fn
	local newFilmMeshes, filmVerts = {}, {}
	if quality.Film and Settings.Get("Highlights") and budgetLevel < 1 then
		local allCoarse = {}
		for c = 1, (cn - 1) * (cn - 1) do
			table.insert(allCoarse, c)
		end
		local sm, verts, _, colors = latticeMesh(coarse, allCoarse, cn, true, true)
		local filmEdge = lodInner / 2
		local fadeStart = filmEdge * 0.6
		-- alpha fades out over the outer third so the edge never shows
		for k, L in verts do
			local edge = math.max(math.abs(coarse[(L - 1) % cn + 1]), math.abs(coarse[(L - 1) // cn + 1]))
			local t = math.clamp((edge - fadeStart) / (filmEdge - fadeStart), 0, 1)
			sm:SetColorAlpha(colors[k], 1 - t * t * (3 - 2 * t))
		end
		newFilmMeshes[1], filmVerts[1] = sm, verts
	end

	-- the parts (CreateMeshPartAsync yields: bail out cleanly if a newer build started meanwhile)
	local everyMesh = {}
	for _, list in { newTileMeshes, newFilmMeshes, { newStatic, fm } } do
		for _, em in list do
			table.insert(everyMesh, em)
		end
	end
	local newTileParts, newFilmParts = {}, {}
	local everyPart = {}
	local function partFor(em: EditableMesh): MeshPart
		local p = AssetService:CreateMeshPartAsync(Content.fromObject(em))
		table.insert(everyPart, p)
		return p
	end
	for i, em in newTileMeshes do
		newTileParts[i] = partFor(em)
	end
	local newStaticPart = if newStatic then partFor(newStatic) else nil
	local newFoam = if fm then partFor(fm) else nil
	for i, em in newFilmMeshes do
		newFilmParts[i] = partFor(em)
	end
	if token ~= buildToken or not running then
		for _, p in everyPart do
			p:Destroy()
		end
		for _, em in everyMesh do
			em:Destroy()
		end
		return
	end
	-- the real positions (SetPosition after creation is not bound by the 2048-stud creation cap)
	for i, em in newTileMeshes do
		if tileShrink[i] < 1 then
			for k, L in tileVerts[i] do
				em:SetPosition(tileVids[i][k], Vector3.new(coords[(L - 1) % n + 1], 0, coords[(L - 1) // n + 1]))
			end
		end
	end
	if newStatic and staticShrink < 1 then
		for k, L in staticVerts do
			newStatic:SetPosition(staticVids[k], Vector3.new(coords[(L - 1) % n + 1], 0, coords[(L - 1) // n + 1]))
		end
	end

	local model = Instance.new("Model")
	model.Name = "OceanSurface"
	model.Archivable = false
	for _, p in everyPart do
		p.Anchored = true
		p.Locked = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Archivable = false -- never saved into the place, even when previewing in Edit mode
		p.Color = Color3.new(1, 1, 1) -- the water parts get their colour from recolour
		p.Parent = model
	end
	local newRoots = {}
	for i, p in newTileParts do
		p.Name = `Tile_{tileKeys[i]}`
		p.DoubleSided = true -- visible from below too
		local root = Instance.new("Bone")
		root.Name = "Root"
		root.Parent = p
		newRoots[i] = root
	end
	if newStaticPart then
		newStaticPart.Name = "Static"
		newStaticPart.DoubleSided = true
	end
	if newFoam then
		newFoam.Name = "OceanFoam"
		newFoam.Material = FOAM_MATERIAL
		newFoam.Transparency = FOAM_TRANSPARENCY
	end
	local newFilmBones, newFilmX, newFilmZ = {}, {}, {}
	for i, p in newFilmParts do
		p.Name = if i == 1 then "OceanFilm" else `OceanFilm{i}`
		p.Material = FILM_MATERIAL
		p.DoubleSided = true
		p.Transparency = 1 - Settings.Get("FilmOpacity")
		for k, L in filmVerts[i] do -- the film bones: one per vertex, always (a few hundred)
			local x, z = coarse[(L - 1) % cn + 1], coarse[(L - 1) // cn + 1]
			local bone = Instance.new("Bone")
			bone.Name = tostring(k)
			bone.Position = Vector3.new(x, 0, z)
			bone.Parent = p
			table.insert(newFilmBones, bone)
			table.insert(newFilmX, x)
			table.insert(newFilmZ, z)
		end
	end

	destroyMesh()
	container, staticPart, staticMesh, foamMesh, foamPart = model, newStaticPart, newStatic, fm, newFoam
	tileParts, tileMeshes, roots = newTileParts, newTileMeshes, newRoots
	filmParts, filmMeshes, filmBones = newFilmParts, newFilmMeshes, newFilmBones
	filmX, filmZ = newFilmX, newFilmZ
	foamIds, foamColorIds = newFoamIds, foamColors
	table.clear(foamX)
	table.clear(foamZ)
	-- the foam fades out over the outer part of its lattice, measured from the camera
	foamFadeTo = math.max(lodInner / 2 - snap / 2, qCell)
	foamFadeFrom = foamFadeTo * 0.6
	for f, L in foamVerts do
		foamX[f], foamZ[f] = fineHalf[(L - 1) % fn + 1], fineHalf[(L - 1) // fn + 1]
	end
	-- the flat per-vertex arrays, one entry per tile vertex
	table.clear(baseX)
	table.clear(baseZ)
	table.clear(invSpacing)
	table.clear(hasSkin)
	table.clear(partOf)
	table.clear(localOf)
	table.clear(latticeOf)
	local triangles = 2 * #staticCells
	for i, verts in tileVerts do
		triangles += 2 * #cellsOf[tileKeys[i]]
		for k, L in verts do
			local xi, zi = (L - 1) % n + 1, (L - 1) // n + 1
			local v = #baseX + 1
			baseX[v], baseZ[v] = coords[xi], coords[zi]
			invSpacing[v] = 1 / (3 * math.max(space[xi], space[zi]))
			hasSkin[v] = skinL[L]
			partOf[v], localOf[v], latticeOf[v] = newTileParts[i], k, L
		end
	end
	local skinRadius = 0
	for v = 1, #baseX do
		if hasSkin[v] then
			skinRadius = math.max(skinRadius, math.sqrt(baseX[v] * baseX[v] + baseZ[v] * baseZ[v]))
		end
	end
	skinFadeTo = math.max(skinRadius - snap, 1)
	skinFadeFrom = skinFadeTo * 0.7
	gridN = n
	gridCoords, skinnedAt, blendOf = coords, skinL, blend
	table.clear(drawn)
	table.clear(morphOff)
	morphStart = -math.huge
	applyLook()
	table.clear(pinned)
	staticTimer = STATIC_REFRESH -- refresh the fields on the first update
	staticDone, coloredOnce = false, false
	table.clear(foamAlphas)
	table.clear(foamKeys)
	lastOx, lastOz = math.huge, math.huge
	lastSeaLevel = math.huge
	Renderer.Stats.Vertices = #baseX + #staticVerts + #foamVerts + #newFilmBones
	Renderer.Stats.Triangles = triangles
	Renderer.Stats.Tiles = #newTileParts

	refreshActive()
	seenNight = -1 -- colours the water and the film
	seenVersion = Waves.Version
	model.Parent = parent
end

local warnedNoMesh = false

-- The flat water. With FlatSea on it is the sea itself; with the dynamic sea it only stands in
-- while the wave mesh cannot be drawn. It is the flat water slab saved with the place when there
-- is one, otherwise one plain part in the water's colour, stretched to the horizon by a BlockMesh
-- and following the camera. No EditableMesh either way, so any device can hold it.
local flatPart: Part? = nil

local function showFlat()
	SurfaceDetail.Stop() -- no wave mesh, no parts for the ripples: free their maps
	showPlaceholders()
	Waves.SetLocalFlat(true)
	if #CollectionService:GetTagged(PLACEHOLDER_TAG) > 0 then
		if flatPart then
			flatPart:Destroy()
			flatPart = nil
		end
		return -- the place's own flat water is the surface
	end
	local part = flatPart
	if not (part and part.Parent) then
		local made = Instance.new("Part")
		made.Name = "OceanFlat"
		made.Size = Vector3.new(2048, 1, 2048)
		made.Anchored = true
		made.Locked = true
		made.CanCollide, made.CanQuery, made.CanTouch = false, false, false
		made.CastShadow = false
		made.Archivable = false
		made.TopSurface = Enum.SurfaceType.Smooth
		local mesh = Instance.new("BlockMesh")
		mesh.Scale = Vector3.new(100, 1, 100)
		mesh.Parent = made
		made.Parent = parent
		flatPart = made
		part = made
	end
	local material, variant = materialFor(Settings.Get("WaterMaterial"))
	local deep, shallow = Settings.Get("DeepColor"), Settings.Get("ShallowColor")
	part.Color = deep:Lerp(shallow, 0.5)
	part.Material = material
	part.MaterialVariant = variant
	part.Reflectance = Settings.Get("Reflectance")
	part.Transparency = Settings.Get("WaterTransparency")
end

-- The wave mesh is on screen: the flat water steps aside.
local function hideFlat()
	if flatPart then
		flatPart:Destroy()
		flatPart = nil
	end
	hidePlaceholders()
	Waves.SetLocalFlat(false)
end

local function note(level: number)
	Renderer.Stats.Level = level
	if container then
		container:SetAttribute("Level", LEVEL_NAMES[level])
	end
end

-- One attempt at `budgetLevel`. A refused build leaves whatever is on screen untouched.
local function attempt(token: number): (boolean, string?)
	table.clear(pendingMeshes)
	local ok, err = pcall(buildOnce, token)
	if not ok then
		for _, em in pendingMeshes do
			em:Destroy()
		end
	end
	table.clear(pendingMeshes) -- owned by the sea on success
	return ok, if ok then nil else tostring(err)
end

local function build()
	buildToken += 1
	local token = buildToken

	if Settings.Get("FlatSea") == true then
		-- a flat sea is the flat water itself: no wave mesh to build
		destroyMesh()
		showFlat()
		budgetLevel = 0
		nextClimb = math.huge
		return
	end
	if not Waves.MeshAvailable() then
		-- no wave mesh without EditableMesh access: the flat water is the sea, for good
		destroyMesh()
		showFlat()
		nextClimb = math.huge
		if not warnedNoMesh then
			warnedNoMesh = true
			warn(
				"[Ocean] EditableMesh is not enabled for this experience (Experience Settings): the sea is flat. Enable it for the dynamic sea."
			)
		end
		return
	end
	if budgetLevel >= FLAT_LEVEL then
		return -- on the flat fallback: the climb brings the mesh back
	end
	building = true
	local ok, err = attempt(token)
	building = false
	if token ~= buildToken then
		return
	end
	if ok then
		hideFlat()
		note(budgetLevel)
		slowSince = nil
		nextClimb = if budgetLevel > 0 then os.clock() + climbDelay else math.huge
		return
	end
	-- refused (the device's EditableMesh budget, most likely): flat now, climb from the bottom
	warn(
		`[Ocean] the sea could not be built at "{LEVEL_NAMES[budgetLevel]}" ({err}): flat for now, retrying from the lowest quality`
	)
	destroyMesh()
	budgetLevel = FLAT_LEVEL
	showFlat()
	note(budgetLevel)
	climbDelay = CLIMB_MIN
	nextClimb = os.clock() + CLIMB_FIRST
end

-- Try the next better rung. Refused: stay where we are and wait twice as long before asking again.
local function climb()
	if building or not running or budgetLevel <= 0 then
		return
	end
	buildToken += 1
	local token = buildToken
	local shown = budgetLevel
	budgetLevel = shown - 1
	building = true
	local ok = attempt(token)
	building = false
	if token ~= buildToken then
		return
	end
	if ok then
		hideFlat()
		note(budgetLevel)
		slowSince = nil
		climbDelay = math.max(CLIMB_MIN, climbDelay * 0.75)
		nextClimb = if budgetLevel > 0 then os.clock() + climbDelay else math.huge
	else
		budgetLevel = shown
		applyQuality() -- the lattice numbers belong to the rung on screen again
		climbDelay = math.min(climbDelay * 2, CLIMB_MAX)
		nextClimb = os.clock() + climbDelay
	end
end

-- The mesh costs too much frame time on this device: one rung down, and no climbing for a while.
local function stepDown()
	if building or budgetLevel >= FLAT_LEVEL - 1 then
		return
	end
	budgetLevel += 1
	climbDelay = math.min(math.max(climbDelay * 2, 20), CLIMB_MAX)
	task.spawn(build)
end

-- The pin of a foam or film vertex inside a dry box: out to the nearest wall and sunk under the
-- floor, so the layer is cut out of the box like the water under it.
local function pinFor(boxes: { Regions.Box }, wx: number, wz: number): { number }?
	for _, box in boxes do
		local bx, bz = wx - box.X, wz - box.Z
		if bx * bx + bz * bz < box.Reach * box.Reach and Regions.CoversXZ(box, wx, wz) then
			local px, pz = Regions.PushOut(box, wx, wz)
			return { px - wx, pz - wz, box.Bottom - DRY_SINK }
		end
	end
	return nil
end

-- Recompute the per-vertex static fields for the mesh centred at (ox, oz): obstacle damping,
-- dry-region pins and the shove-clamp candidates.
local function refreshStatic(ox: number, oz: number)
	table.clear(pinned)
	table.clear(dampOf)
	table.clear(nearDry)
	table.clear(foamDamp)
	table.clear(filmDamp)
	table.clear(foamPin)
	table.clear(filmPin)
	if not container then
		return
	end
	local obstacles = Waves.ObstaclesNear(ox, oz, animatedRadius * 1.5)
	if #obstacles > 0 then
		for _, list in { near, far } do
			for _, v in list do
				local damp = Waves.Damp(obstacles, ox + baseX[v], oz + baseZ[v])
				if damp < 1 then
					dampOf[v] = damp
				end
			end
		end
		for f = 1, #foamX do
			local damp = Waves.Damp(obstacles, ox + foamX[f], oz + foamZ[f])
			if damp < 1 then
				foamDamp[f] = damp
			end
		end
		for j = 1, #filmX do
			local damp = Waves.Damp(obstacles, ox + filmX[j], oz + filmZ[j])
			if damp < 1 then
				filmDamp[j] = damp
			end
		end
	end
	dryNear = Regions.Near(ox, oz, animatedRadius * 1.5)
	local boxes = Regions.List()
	if #boxes == 0 then
		return
	end
	for f = 1, #foamX do
		foamPin[f] = pinFor(boxes, ox + foamX[f], oz + foamZ[f])
	end
	for j = 1, #filmX do
		filmPin[j] = pinFor(boxes, ox + filmX[j], oz + filmZ[j])
	end
	local n = gridN
	local inBox: { [number]: Regions.Box } = {} -- by lattice point: shared vertices agree
	for v = 1, #baseX do
		local wx, wz = ox + baseX[v], oz + baseZ[v]
		for _, box in boxes do
			local bx, bz = wx - box.X, wz - box.Z
			if bx * bx + bz * bz < box.Reach * box.Reach and Regions.CoversXZ(box, wx, wz) then
				inBox[latticeOf[v]] = box
				break
			end
		end
	end
	-- outside vertices a wave could shove into a box: two cells + a little, at this vertex's spacing
	for v = 1, #baseX do
		if not inBox[latticeOf[v]] then
			local wx, wz = ox + baseX[v], oz + baseZ[v]
			local margin = 2 / (3 * invSpacing[v]) + 4 -- cells, not the real shove bound
			for _, box in dryNear do
				if Regions.CoversXZ(box, wx, wz, margin) then
					nearDry[v] = true
					break
				end
			end
		end
	end
	for v = 1, #baseX do
		local L = latticeOf[v]
		local box = inBox[L]
		if not box then
			continue
		end
		local wx, wz = ox + baseX[v], oz + baseZ[v]
		local y = box.Bottom - DRY_SINK
		-- the rim (any of its 8 grid neighbours is outside) also goes to the wall, so the dive from
		-- the water line down to the sunk floor happens entirely outside the box
		local xi, zi = (L - 1) % n + 1, (L - 1) // n + 1
		local rim = false
		for dz = -1, 1 do
			for dx = -1, 1 do
				local nx, nz = xi + dx, zi + dz
				if nx >= 1 and nx <= n and nz >= 1 and nz <= n and not inBox[(nz - 1) * n + nx] then
					rim = true
				end
			end
		end
		if rim then
			local px, pz = Regions.PushOut(box, wx, wz)
			pinned[v] = { px - wx, pz - wz, y }
		else
			pinned[v] = { 0, 0, y }
		end
	end
end

-- The underwater tint is ours: a full-screen frame in the player's PlayerGui (CoreGui for the
-- Edit-mode preview, which Team Create never syncs), driven from the Underwater* settings so
-- zones, weathers and presets can vary it, alive with or without a wave mesh.
local tintFrame: Frame? = nil
-- The camera's near plane sits a little ahead of and below its position: the tint comes on this
-- far above the water line, so the view never shows the underside of the surface untinted.
local TINT_MARGIN = 0.6
local surfaceAt: (x: number, z: number) -> number -- the drawn surface; defined below the wave sum

local function tintHome(): Instance?
	if parent:IsA("Camera") then
		return game:GetService("CoreGui")
	end
	local player = Players.LocalPlayer
	return if player then player:FindFirstChildOfClass("PlayerGui") else nil
end

local function applyTint(focus: Vector3)
	local tint = tintFrame
	if not (tint and tint.Parent) then
		local home = tintHome()
		if not home then
			return
		end
		local gui = Instance.new("ScreenGui")
		gui.Name = UNDERWATER_GUI
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = -10 -- under the game's own UI
		gui.ResetOnSpawn = false
		gui.Archivable = false
		tint = Instance.new("Frame")
		tint.Size = UDim2.fromScale(1, 1)
		tint.BorderSizePixel = 0
		tint.Visible = false
		tint.Parent = gui
		gui.Parent = home
		tintFrame = tint
	end
	local under = Settings.Get("UnderwaterEnabled")
		and focus.Y < surfaceAt(focus.X, focus.Z) + TINT_MARGIN
		and not Regions.IsDry(focus)
	if tint.Visible ~= under then
		tint.Visible = under
	end
	if under then
		local color, transparency = Settings.Get("UnderwaterTint"), 1 - Settings.Get("UnderwaterOpacity")
		if Settings.Get("DynamicLighting") then -- darkens with the sun, like the water itself
			local night = nightFactor()
			color = Color3.new(color.R * night, color.G * night, color.B * night)
		end
		if tint.BackgroundColor3 ~= color then
			tint.BackgroundColor3 = color
		end
		if tint.BackgroundTransparency ~= transparency then
			tint.BackgroundTransparency = transparency
		end
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
local shading = 1 -- WaveShading, read once per update
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

-- World Y of the surface as this client draws it at (x, z): the wave sum of the mesh on screen
-- (its rung, its finest cell, the weather layers here, obstacles), inverted like Waves.Height so
-- the sideways shove of the waves is accounted for. Sea level on the flat water.
function surfaceAt(x: number, z: number): number
	if not container or flatSea then
		return Waves.SeaLevel
	end
	local now = workspace:GetServerTimeNow()
	local t = Waves.Time()
	local inv = 1 / (3 * lodCell)
	local zones = Waves.ZonesNear(x, z, 1)
	local obstacles = Waves.ObstaclesNear(x, z, 1)
	local damp = if #obstacles > 0 then Waves.Damp(obstacles, x, z) else 1
	local savedCount, savedZones, savedNow, savedLoaded = gCount, gZones, gNow, gGlobalLoaded
	gZones, gNow = zones, now
	gCount = Waves.Gather(zones, x, z, now)
	local px, pz, y = x, z, 0
	for _ = 1, 3 do
		local dx, dy, dz = waveAt(px, pz, inv, t)
		px, pz, y = x - dx * damp, z - dz * damp, dy * damp
	end
	gCount, gZones, gNow, gGlobalLoaded = savedCount, savedZones, savedNow, savedLoaded
	return Waves.SeaLevel + y
end

-- Where the last frame's drawing of lattice point L comes from, added to the sources list with
-- weight w: its own bone's values, the two bones it rides, or nothing (at rest past the skin).
local srcAt, srcW = table.create(8, 0), table.create(8, 0)
local function addSource(count: number, L: number, w: number): number
	if w == 0 then
		return count
	end
	if skinnedAt[L] then
		count += 1
		srcAt[count], srcW[count] = (L - 1) * VALUES, w
		return count
	end
	local pair = blendOf[L]
	if pair then
		srcAt[count + 1], srcW[count + 1] = (pair[1] - 1) * VALUES, w * pair[3]
		srcAt[count + 2], srcW[count + 2] = (pair[2] - 1) * VALUES, w * (1 - pair[3])
		return count + 2
	end
	return count
end

-- The lattice axis cell holding local coordinate x: its lower index and x's place across it (0 = outside).
local function locate(x: number): (number, number)
	local c, n = gridCoords, gridN
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

-- The mesh just re-centred by (sx, sz): for every animated vertex, the old surface at its new place
-- (the old lattice's drawn values, bilinear across the old cell it now sits in).
local cellX, fracX, cellZ, fracZ = {}, {}, {}, {}
local function captureMorph(sx: number, sz: number)
	local n = gridN
	for i = 1, n do
		cellX[i], fracX[i] = locate(gridCoords[i] + sx)
		cellZ[i], fracZ[i] = locate(gridCoords[i] + sz)
	end
	for pass = 1, 2 do
		local list = if pass == 1 then near else far
		for _, v in list do
			local L = latticeOf[v]
			local xi, zi = (L - 1) % n + 1, (L - 1) // n + 1
			local j, k = cellX[xi], cellZ[zi]
			local o = (v - 1) * VALUES
			if j == 0 or k == 0 then
				morphFrom[o + 1] = nil
				continue
			end
			local tx, tz = fracX[xi], fracZ[zi]
			local a = (k - 1) * n + j
			local count = addSource(0, a, (1 - tx) * (1 - tz))
			count = addSource(count, a + 1, tx * (1 - tz))
			count = addSource(count, a + n, (1 - tx) * tz)
			count = addSource(count, a + n + 1, tx * tz)
			for q = 1, VALUES do
				local value = 0
				for s = 1, count do
					value += (drawn[srcAt[s] + q] or 0) * srcW[s]
				end
				morphFrom[o + q] = value
			end
		end
	end
end

local function update()
	local model, camera = container, workspace.CurrentCamera
	if not camera then
		return
	end
	-- The mesh (and the tint) update at UpdateRate, not at the render rate: at 200 fps that is a
	-- third of the bone traffic for the same-looking sea. Accumulator, so it averages out exactly.
	local started = os.clock()
	if started < nextUpdate then
		return
	end
	local period = 1 / Settings.Get("UpdateRate")
	nextUpdate = math.max(nextUpdate + period, started - period)
	applyTint(camera.CFrame.Position)
	if flatPart then
		local focus = camera.CFrame.Position
		flatPart.CFrame = CFrame.new(math.round(focus.X / 64) * 64, Waves.SeaLevel - 0.5, math.round(focus.Z / 64) * 64)
	end
	if started >= nextClimb and not building then
		nextClimb = math.huge -- climb sets the next one
		task.spawn(climb)
	end
	if not model then
		return
	end

	if seenVersion ~= Waves.Version then
		seenVersion = Waves.Version
		refreshActive() -- wavelengths may have changed which vertices can move
		staticDone, coloredOnce = false, false
	end

	local focus = camera.CFrame.Position
	local fx, fz = focus.X, focus.Z
	local look = camera.CFrame.LookVector
	local lookX, lookZ = look.X, look.Z
	local lookLen = math.sqrt(lookX * lookX + lookZ * lookZ)
	if lookLen > 1e-3 then
		lookX, lookZ = lookX / lookLen, lookZ / lookLen
	else
		lookX, lookZ = 0, 0 -- straight down: nothing is "behind"
	end
	local ox = math.round(focus.X / snap) * snap
	local oz = math.round(focus.Z / snap) * snap
	local moved = ox ~= lastOx or oz ~= lastOz
	local prevOx, prevOz = lastOx, lastOz
	lastOx, lastOz = ox, oz
	local fm, fp = foamMesh, foamPart
	local seaLevel = Waves.SeaLevel
	if seaLevel ~= lastSeaLevel then -- only SeaLevel moves the skinned parts; the re-centre is in the bones
		lastSeaLevel = seaLevel
		for _, p in tileParts do
			p.CFrame = CFrame.new(0, seaLevel, 0)
		end
		if fp then
			fp.CFrame = CFrame.new(0, seaLevel + FOAM_LIFT, 0)
		end
		for _, p in filmParts do
			p.CFrame = CFrame.new(0, seaLevel + FILM_LIFT, 0)
		end
	end
	if moved then
		local offset = CFrame.new(ox, 0, oz)
		for _, root in roots do
			root.Transform = offset
		end
		for _, v in idle do
			(bones[v] :: Bone).Transform = offset
		end
		if staticPart then -- no bones: a plain part, moved by whole texture tiles
			staticPart.CFrame = CFrame.new(ox, seaLevel, oz)
		end
	end

	local now = workspace:GetServerTimeNow()
	local t = Waves.Time()

	local night = if Settings.Get("DynamicLighting") then nightFactor() else 1
	if math.abs(night - seenNight) > 0.01 then
		seenNight = night
		recolour(night)
	end

	gZones = Waves.ZonesNear(ox, oz, animatedRadius * 1.5)
	gNow = now
	staticTimer += period
	if moved or staticTimer >= STATIC_REFRESH then
		staticTimer = 0
		refreshStatic(ox, oz)
	end
	gCount = Waves.Gather(NO_ZONES, ox, oz, now) -- the global weather's layers
	blendLook(gCount)
	gGlobalLoaded = true
	Renderer.Stats.Layers = if #gZones > 0 then -#gZones else gCount

	local clamp, floor = math.clamp, math.floor
	local nightKey = floor(night * 100) * 262144
	local fineInv = 1 / (3 * lodCell)

	frame += 1
	flatSea = Settings.Get("FlatSea") == true
	shading = Settings.Get("WaveShading")
	-- StaticWaves (or a flat sea): after one full pass nothing moves until the mesh re-centres or
	-- the waves change. DynamicColors off: foam is written once the same way.
	if (flatSea or Settings.Get("StaticWaves")) and staticDone and not moved then
		return
	end
	local colorPass = moved or (frame % quality.ColorEvery == 0 and (Settings.Get("DynamicColors") or not coloredOnce))
	local updated = 0
	local behindPass = moved or frame % BEHIND_EVERY == 0
	-- Near vertices every frame; the coarser LOD ring at a lower rate, all of it on the same frames
	-- (staggering neighbours onto different frames shows as corrugation at grazing angles).
	-- The mesh just re-centred: every vertex must be placed against the new origin THIS frame, or the
	-- half-rate ring sits a tile off for a frame (the "chop" when moving fast).
	local farPass = moved or frame % quality.FarEvery == 0
	-- a re-centre of a few tiles eases in from the old surface; a jump (teleport, rebuild) does not
	if moved then
		if math.abs(ox - prevOx) <= 4 * snap and math.abs(oz - prevOz) <= 4 * snap then
			captureMorph(ox - prevOx, oz - prevOz)
			morphStart = started
		else
			table.clear(morphFrom)
			morphStart = -math.huge
		end
	end
	local easing = math.max(1 - (started - morphStart) / MORPH_TIME, 0)
	for pass = 1, if farPass then 2 else 1 do
		local list: { number } = if pass == 1 then near else far
		for _, v in list do
			local lx, lz = baseX[v], baseZ[v]
			local wx, wz = ox + lx, oz + lz
			-- vertices behind the camera can't be seen: keep them alive at a low rate for when it turns
			if not behindPass and (wx - fx) * lookX + (wz - fz) * lookZ < -BEHIND_MARGIN then
				continue
			end
			updated += 1
			local ddx, ddz = wx - fx, wz - fz
			local dist = math.sqrt(ddx * ddx + ddz * ddz)
			local inv = 1 / (3 * math.min(lodCell + math.max(dist - lodInner, 0) * lodSlope, lodCap))
			gatherAt(wx, wz)
			local dx, dy, dz, gx, gz, sxx, sxz, szz = waveAt(wx, wz, inv, t)
			local fade = 1
			if dist > skinFadeFrom then
				local ft = clamp((dist - skinFadeFrom) / (skinFadeTo - skinFadeFrom), 0, 1)
				fade = 1 - ft * ft * (3 - 2 * ft)
				dx, dy, dz = dx * fade, dy * fade, dz * fade
			end
			local damp = dampOf[v]
			if damp then
				dx, dy, dz = dx * damp, dy * damp, dz * damp
				fade *= damp
			end
			local pin = pinned[v]
			local free = true -- no dry region decides where this vertex goes: it may ease
			if pin then
				-- inside a dry region: sunk under its floor (a box above the water leaves it alone)
				dx, dz = pin[1], pin[2]
				dy = math.min(dy, pin[3] - seaLevel)
				fade = 0 -- flat down there
				free = false
			elseif nearDry[v] then
				-- outside, but the Gerstner shove would carry it in: clamp to the wall
				free = false
				for _, box in dryNear do
					local cx, cz, shoved = Regions.PushOut(box, wx + dx, wz + dz)
					if shoved then
						dx, dz = cx - wx, cz - wz
						break
					end
				end
			end
			gx, gz, sxx, sxz, szz = gx * fade, gz * fade, sxx * fade, sxz * fade, szz * fade
			local o = (v - 1) * VALUES
			if moved then -- re-sampled here: start from the old surface
				local from = morphFrom[o + 1]
				if from and free then
					morphOff[o + 1], morphOff[o + 2], morphOff[o + 3] =
						from - dx, morphFrom[o + 2] - dy, morphFrom[o + 3] - dz
					morphOff[o + 4], morphOff[o + 5] = morphFrom[o + 4] - gx, morphFrom[o + 5] - gz
					morphOff[o + 6], morphOff[o + 7] = morphFrom[o + 6] - sxx, morphFrom[o + 7] - sxz
					morphOff[o + 8] = morphFrom[o + 8] - szz
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
			local d = (latticeOf[v] - 1) * VALUES
			drawn[d + 1], drawn[d + 2], drawn[d + 3], drawn[d + 4] = dx, dy, dz, gx
			drawn[d + 5], drawn[d + 6], drawn[d + 7], drawn[d + 8] = gz, sxx, sxz, szz
			local bone = bones[v] :: Bone
			bone.Transform = boneCFrame(ox + dx, dy, oz + dz, 1, gx, gz, sxx, sxz, szz)
		end
	end

	-- foam and film ride the same waves on their own coarse lattice (fine spacing: it is inside
	-- the full-detail area). The foam's positions are written outright (plain mesh); its alpha
	-- and colour only on colour passes. Neither touches the base.
	if fm then
		local sameLayers = #gZones == 0
		for f = 1, #foamX do
			local lx, lz = foamX[f], foamZ[f]
			local wx, wz = ox + lx, oz + lz
			if not behindPass and (wx - fx) * lookX + (wz - fz) * lookZ < -BEHIND_MARGIN then
				continue
			end
			gatherAt(wx, wz)
			local dx, dy, dz = waveAt(wx, wz, fineInv, t)
			local shore = 0 -- 0..1 how much this point is in an obstacle's calming ring
			local damp = foamDamp[f]
			if damp then
				-- peaks halfway across the ring (the "breaking" line), and only where a crest of the
				-- incoming wave is passing: the wash moves with the waves instead of sitting there
				shore = damp * (1 - damp) * 4 * clamp(2 * dy / lookMaxAmp, 0, 1)
				dx, dy, dz = dx * damp, dy * damp, dz * damp
			end
			local pin = foamPin[f]
			if pin then -- inside a dry region: at its wall, sunk under its floor
				dx, dz = pin[1], pin[2]
				dy = math.min(dy, pin[3] - seaLevel)
			else -- outside: the waves' sideways shove never carries it in
				for _, box in dryNear do
					local cx, cz, shoved = Regions.PushOut(box, wx + dx, wz + dz)
					if shoved then
						dx, dz = cx - wx, cz - wz
						break
					end
				end
			end
			fm:SetPosition(foamIds[f], Vector3.new(wx + dx, dy, wz + dz))
			if not colorPass then
				continue
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
				fm:SetColor(foamColorIds[f], Color3.new(foamR * night, foamG * night, foamB * night))
				local alpha = (lookWebOpacity + (lookFoamOpacity - lookWebOpacity) * foam) * fade
				if alpha ~= foamAlphas[f] then
					foamAlphas[f] = alpha
					fm:SetColorAlpha(foamColorIds[f], alpha)
				end
			end
		end
	end

	-- the film: the same waves on the same vertices as the water under it (bones, so nothing is written to its mesh)
	for j, bone in filmBones do
		local wx, wz = ox + filmX[j], oz + filmZ[j]
		if not behindPass and (wx - fx) * lookX + (wz - fz) * lookZ < -BEHIND_MARGIN then
			continue
		end
		gatherAt(wx, wz)
		local dx, dy, dz, gx, gz, sxx, sxz, szz = waveAt(wx, wz, fineInv, t)
		local damp = filmDamp[j] or 1 -- calmed by obstacles like the water under it
		if damp < 1 then
			dx, dy, dz = dx * damp, dy * damp, dz * damp
		end
		local pin = filmPin[j]
		if pin then -- inside a dry region: at its wall, sunk under its floor
			dx, dz = pin[1], pin[2]
			dy = math.min(dy, pin[3] - seaLevel)
			damp = 0
		else -- outside: the waves' sideways shove never carries it in
			for _, box in dryNear do
				local cx, cz, shoved = Regions.PushOut(box, wx + dx, wz + dz)
				if shoved then
					dx, dz = cx - wx, cz - wz
					break
				end
			end
		end
		bone.Transform = boneCFrame(ox + dx, dy, oz + dz, damp, gx, gz, sxx, sxz, szz)
	end

	if not moved then -- a re-centre frame skips the behind-camera vertices; the next full pass counts
		staticDone = true
		if colorPass then
			coloredOnce = true
		end
	end
	Renderer.Stats.UpdateMs = (os.clock() - started) * 1000
	if Renderer.Stats.UpdateMs > SLOW_MS then
		slowSince = slowSince or started
		if started - slowSince > SLOW_FOR then
			slowSince = nil
			stepDown()
		end
	else
		slowSince = nil
	end
	if Renderer.Stats.UpdateMs > 20 then -- a hitch: count it where the Properties panel can see it
		Renderer.Stats.Hitches += 1
		model:SetAttribute("Hitches", Renderer.Stats.Hitches)
		model:SetAttribute("WorstMs", math.round(Renderer.Stats.UpdateMs))
	end
	if frame % 30 == 0 then -- readable from anywhere (Properties panel, command bar) without a require
		model:SetAttribute("UpdateMs", math.round(Renderer.Stats.UpdateMs * 100) / 100)
		model:SetAttribute("Animated", Renderer.Stats.Active)
		model:SetAttribute("Bones", Renderer.Stats.Bones)
		model:SetAttribute("Tiles", Renderer.Stats.Tiles)
		model:SetAttribute("Updated", updated)
	end
end

-- `into` lets the Studio plugin preview under the Camera (which is never saved with the place).
function Renderer.Init(into: Instance?)
	if running then
		return
	end
	running = true
	parent = into or workspace.Terrain -- the game's sea lives under Terrain; the preview under the Camera
	-- with streaming the placeholder slab can arrive after us: hide it whenever it shows up
	placeholderAdded = CollectionService:GetInstanceAddedSignal(PLACEHOLDER_TAG):Connect(function()
		if container then
			hidePlaceholders() -- the wave mesh is the sea: the flat water stands aside
		elseif flatPart or Settings.Get("FlatSea") == true then
			showFlat() -- the flat water is the sea: the place's own slab takes over
		end
	end)
	connection = Settings.OnChanged(function(name)
		local entry = Settings.Spec[name]
		if (entry and entry.Rebuild) or name == "FlatSea" then
			task.spawn(build)
		elseif
			name == "StaticWaves"
			or name == "DynamicColors"
			or name == "DynamicLighting"
			or name == "WaveShading"
		then
			staticDone, coloredOnce = false, false
		elseif
			name == "Reflectance"
			or name == "WaterTransparency"
			or name == "WaterMaterial"
			or name == "WaterTexture"
			or name == "FoamTexture"
			or name == "FoamStyle"
			or name == "Lit"
			or name == "SurfaceDetail"
			or name == "RippleStrength"
			or name == "WaterRoughness"
		then
			applyLook()
		elseif name == "FilmOpacity" then
			for _, p in filmParts do
				p.Transparency = 1 - Settings.Get("FilmOpacity")
			end
		elseif name == "NightBrightness" or name == "DeepColor" or name == "ShallowColor" then
			seenNight = -1
		end
	end)
	task.spawn(build)
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, update)
end

-- Puts the sea on a rung of the quality ladder (0 = full ... 6 = flat), as if the device had
-- forced it there; it climbs back up from that rung on its own. For testing low-end behaviour.
function Renderer.SetLevel(level: number)
	if not running then
		return
	end
	budgetLevel = math.clamp(math.floor(level), 0, FLAT_LEVEL)
	climbDelay = CLIMB_MIN
	if budgetLevel >= FLAT_LEVEL then
		buildToken += 1
		destroyMesh()
		showFlat()
		note(budgetLevel)
		nextClimb = os.clock() + CLIMB_FIRST
	else
		task.spawn(build)
	end
end

function Renderer.Stop()
	if not running then
		return
	end
	running = false
	buildToken += 1
	RunService:UnbindFromRenderStep(BIND_NAME)
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if placeholderAdded then
		placeholderAdded:Disconnect()
		placeholderAdded = nil
	end
	destroyMesh()
	hideFlat()
	showPlaceholders() -- after hideFlat, which hides them: the sea is gone, the flat water is back
	budgetLevel = 0
	climbDelay, nextClimb, slowSince, building = CLIMB_MIN, math.huge, nil, false
	if tintFrame then
		local gui = tintFrame.Parent
		if gui then
			gui:Destroy()
		end
		tintFrame = nil
	end
	SurfaceTexture.Stop()
	SurfaceDetail.Stop()
end

return Renderer

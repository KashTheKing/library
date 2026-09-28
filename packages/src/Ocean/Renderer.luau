--!native
--!optimize 2
--[[
	Client-only. One EditableMesh that follows the camera = infinite ocean in every direction.

	This module builds the mesh and runs each update (re-centre, time, colours, the tint); the
	per-point drawing (waves onto bones, foam, film, dry cut) is Draw.luau, in parallel on worker
	Actors in a running game.

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
	        (see Draw's boneCFrame). Optionally a SurfaceAppearance on top with ripples lit per pixel
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

local Contact = require(script.Parent.Contact)
local Draw = require(script.Parent.Draw)
local Regions = require(script.Parent.Regions)
local Settings = require(script.Parent.Settings)
local Spectral = require(script.Parent.Spectral)
local SurfaceDetail = require(script.Parent.SurfaceDetail)
local SurfaceTexture = require(script.Parent.SurfaceTexture)
local Waves = require(script.Parent.Waves)

local Renderer = {}
Renderer.Stats =
	{ Vertices = 0, Active = 0, Triangles = 0, UpdateMs = 0, DrawMs = 0, Layers = 0, Bones = 0, Hitches = 0, Tiles = 0 }

local BIND_NAME = "OceanSurface"
local PLACEHOLDER_TAG = "OceanPlaceholder" -- the plugin's flat stand-in water: hidden while the real sea runs
local FOAM_MATERIAL = Enum.Material.SmoothPlastic
local DEFAULT_MATERIAL = Enum.Material.SmoothPlastic
local TILE_CELLS = 4 -- the textures repeat every this many fine cells (and the mesh re-centres by that)
local FOAM_TRANSPARENCY = 0.02
local FOAM_LIFT = 0.2 -- studs above the base, to avoid z-fighting; the film sits above the foam
local FILM_LIFT = 0.35
local STATIC_REFRESH = 0.25 -- s between re-evaluations of the per-vertex obstacle damping
-- Not Neon: emissive glow ignores transparency and washes the whole near field white at any opacity.
local FILM_MATERIAL = Enum.Material.SmoothPlastic
local UNDERWATER_GUI = "OceanUnderwater" -- the module's own full-screen tint frame, shown while the camera is under
local MAX_CELLS_PER_SIDE = 49
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
local adaptConnection: RBXScriptConnection? = nil
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
		FarEvery = 2,
	},
}
local quality = QUALITY.Regular
local qCell, qInner, qOuter = 8, 24, 25 -- the tier-scaled mesh settings in force

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
local latticeOf: { number } = {} -- vertex -> lattice point index (zi - 1) * n + xi
local near: { number } = {} -- full-detail vertices some wave can move: updated every frame
local far: { number } = {} -- LOD-ring vertices: updated every other frame, all together
local idle: { number } = {} -- skinned vertices no current wave can move: placed on re-centre only
-- the foam lattice: FINE spacing over the inner half of the full-detail area (coarser and the base
-- pokes through between its vertices), one plain mesh. Index f.
local foamX: { number } = {}
local foamZ: { number } = {}
local foamIds: { number } = {}
local foamColorIds: { number } = {}
-- the film: the foam's lattice (the base's own vertices over the inner half), skinned. Index j.
local filmBones: { Bone } = {}
-- Foam and film vertices sit on base lattice points, so they take the base's result there instead of
-- summing the waves again (Draw.luau)
local foamLattice: { number } = {} -- foam vertex -> base lattice point
local filmLattice: { number } = {} -- film bone -> base lattice point
local lastSeaLevel = math.huge -- the parts' height last written
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
local morphStart = -math.huge
local flatSea = false -- FlatSea: no displacement anywhere; everything else (look, foam, film, tint) stays
local WORKERS = 4 -- Actors drawing the mesh in parallel, when the game is running on a client
local workers: { Actor } = {}
local workerBuild: { [Actor]: number } = {} -- the build each worker has been handed
local published: SharedTable? = nil -- each update's frame, for the workers
local forwarded: { [string]: any } = {} -- the client-local setting overrides the workers have
local drawData: Draw.Data? = nil -- the build on screen, as Draw takes it
local buildCount = 0
local seenVersion = -1
local seenNight = -1

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

-- The film is built only when it shows: at FilmOpacity 0 its bones would cost frame time for nothing.
local function wantFilm(): boolean
	return quality.Film and Settings.Get("Highlights") and budgetLevel < 1 and Settings.Get("FilmOpacity") > 0
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
	for _, part in Spectral.Parts() do -- the FFT sea's tiles, when it is the sea
		table.insert(list, part)
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
	local r, g, b = Draw.WaterColour(workspace:GetServerTimeNow())
	local colour = Color3.new(r * night, g * night, b * night)
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
	drawData = nil
	Draw.Unload()
	table.clear(tileParts)
	table.clear(tileMeshes)
	table.clear(roots)
	table.clear(filmParts)
	table.clear(filmMeshes)
	table.clear(bones)
	table.clear(filmBones)
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
	if wantFilm() then
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
	local newFilmBones = {}
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
		end
	end

	destroyMesh()
	container, staticPart, staticMesh, foamMesh, foamPart = model, newStaticPart, newStatic, fm, newFoam
	tileParts, tileMeshes, roots = newTileParts, newTileMeshes, newRoots
	filmParts, filmMeshes, filmBones = newFilmParts, newFilmMeshes, newFilmBones
	foamIds, foamColorIds = newFoamIds, foamColors
	table.clear(foamX)
	table.clear(foamZ)
	-- the foam fades out over the outer part of its lattice, measured from the camera
	foamFadeTo = math.max(lodInner / 2 - snap / 2, qCell)
	foamFadeFrom = foamFadeTo * 0.6
	-- a foam / film lattice index i is base lattice index m + i - (fn + 1) / 2 (fn is odd: the inner
	-- area is an even number of cells)
	local shift = m - (fn + 1) // 2
	local function onBase(L: number): number
		return ((L - 1) // fn + shift) * n + (L - 1) % fn + 1 + shift
	end
	table.clear(foamLattice)
	for f, L in foamVerts do
		foamX[f], foamZ[f] = fineHalf[(L - 1) % fn + 1], fineHalf[(L - 1) // fn + 1]
		foamLattice[f] = onBase(L)
	end
	table.clear(filmLattice)
	for _, verts in filmVerts do
		for _, L in verts do
			table.insert(filmLattice, onBase(L))
		end
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
	morphStart = -math.huge
	applyLook()
	staticTimer = STATIC_REFRESH -- refresh the fields on the first update
	staticDone, coloredOnce = false, false
	lastOx, lastOz = math.huge, math.huge
	lastSeaLevel = math.huge
	Renderer.Stats.Vertices = #baseX + #staticVerts + #foamVerts + #newFilmBones
	Renderer.Stats.Triangles = triangles
	Renderer.Stats.Tiles = #newTileParts

	refreshActive() -- also gives every skinned vertex its Bone
	seenNight = -1 -- colours the water and the film
	seenVersion = Waves.Version
	buildCount += 1
	-- dense arrays (false where there is nothing): a message to an Actor copies a table with gaps
	-- only up to its first gap
	local points = n * n
	local skinnedAt, blendOf = table.create(points, false), table.create(points, false)
	for L in skinL do
		skinnedAt[L] = true
	end
	for L, pair in blend do
		blendOf[L] = pair
	end
	local boneOf = table.create(#baseX, false)
	for v = 1, #baseX do
		boneOf[v] = bones[v] or false
	end
	local newData: Draw.Data = {
		Build = buildCount,
		N = n,
		Coords = coords,
		Skinned = skinnedAt,
		Blend = blendOf,
		X = baseX,
		Z = baseZ,
		Inv = invSpacing,
		Lattice = latticeOf,
		Bones = boneOf,
		FoamMesh = fm,
		FoamIds = foamIds,
		FoamColorIds = foamColorIds,
		FoamX = foamX,
		FoamZ = foamZ,
		FoamLattice = foamLattice,
		FilmBones = filmBones,
		FilmLattice = filmLattice,
		Roots = roots,
		Static = staticPart,
		LodCell = lodCell,
		LodInner = lodInner,
		LodSlope = lodSlope,
		LodCap = lodCap,
		SkinFadeFrom = skinFadeFrom,
		SkinFadeTo = skinFadeTo,
		FoamFadeFrom = foamFadeFrom,
		FoamFadeTo = foamFadeTo,
	}
	drawData = newData
	if not published then
		Draw.Load(newData, 1, 1) -- no workers: this module draws all of it
	end
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
	Contact.SetSuspended(level >= 2) -- the contact foam is among the first things to go
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
		Spectral.StopRender()
		destroyMesh()
		showFlat()
		budgetLevel = 0
		nextClimb = math.huge
		return
	end
	if not Waves.MeshAvailable() then
		-- no wave mesh without EditableMesh access: the flat water is the sea, for good
		Spectral.StopRender()
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
	Spectral.StopRender()
	if Spectral.Active() then
		-- WaveMode = FFT: its own clipmap is the sea; the Gerstner mesh, its bones and its rungs stand aside
		-- (the adaptive quality still steps the clipmap down and up, see stepDown)
		destroyMesh()
		hideFlat()
		budgetLevel = math.min(budgetLevel, Spectral.MaxRung)
		nextClimb = if budgetLevel > 0 then os.clock() + climbDelay else math.huge
		note(budgetLevel)
		-- gives its tiles the water's material and ripples; a higher rung is a coarser clipmap
		Spectral.StartRender(parent, applyLook, budgetLevel)
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
	if Spectral.Active() then
		-- the FFT sea: one rung finer clipmap (the build below is the Gerstner mesh's)
		budgetLevel -= 1
		climbDelay = math.max(CLIMB_MIN, climbDelay * 0.75)
		build()
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
	if building or budgetLevel >= (if Spectral.Active() then Spectral.MaxRung else FLAT_LEVEL - 1) then
		return
	end
	budgetLevel += 1
	climbDelay = math.min(math.max(climbDelay * 2, 20), CLIMB_MAX)
	task.spawn(build)
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

-- Underwater blur and depth of field: two effects in Lighting the module owns, faded in and out with
-- the tint (and only while it is on).
local BLUR_NAME, FOCUS_NAME = "OceanUnderwaterBlur", "OceanUnderwaterFocus"
local blurEffect: BlurEffect? = nil
local focusEffect: DepthOfFieldEffect? = nil
local underwaterMix = 0 -- 0 = above the water, 1 = fully under: the effects' strength

local function applyUnderwaterEffects(under: boolean)
	local size, focus = Settings.Get("UnderwaterBlur"), Settings.Get("UnderwaterFocus")
	local target = if under then 1 else 0
	underwaterMix += (target - underwaterMix) * 0.2
	if math.abs(target - underwaterMix) < 0.01 then
		underwaterMix = target
	end
	local wantBlur, wantFocus = underwaterMix > 0 and size > 0, underwaterMix > 0 and focus > 0
	if wantBlur then
		if not (blurEffect and blurEffect.Parent) then
			local made = Instance.new("BlurEffect")
			made.Name = BLUR_NAME
			made.Archivable = false
			made.Parent = Lighting
			blurEffect = made
		end
		(blurEffect :: BlurEffect).Enabled = true
		(blurEffect :: BlurEffect).Size = size * underwaterMix
	elseif blurEffect then
		blurEffect.Enabled = false
	end
	if wantFocus then
		if not (focusEffect and focusEffect.Parent) then
			local made = Instance.new("DepthOfFieldEffect")
			made.Name = FOCUS_NAME
			made.Archivable = false
			made.FocusDistance = 0
			made.NearIntensity = 0
			made.Parent = Lighting
			focusEffect = made
		end
		local effect = focusEffect :: DepthOfFieldEffect
		effect.Enabled = true
		effect.InFocusRadius = focus
		effect.FarIntensity = 0.85 * underwaterMix
	elseif focusEffect then
		focusEffect.Enabled = false
	end
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
		Spectral.SetDoubleSided(under) -- the FFT sea shows its underside while the camera is below
	end
	applyUnderwaterEffects(under)
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

-- World Y of the surface as this client draws it at (x, z): the wave sum of the mesh on screen
-- (its rung, its finest cell, the weather layers here, obstacles), inverted like Waves.Height so
-- the sideways shove of the waves is accounted for. Sea level on the flat water.
function surfaceAt(x: number, z: number): number
	if Spectral.Rendering() then
		return Waves.Height(x, z)
	end
	if not container or flatSea then
		return Waves.SeaLevel
	end
	return Draw.Height(x, z, 1 / (3 * lodCell))
end

-- Drawing: with the game running on a client, WORKERS Actors each draw a share of the mesh in
-- parallel (Draw.luau, Worker.server.luau); otherwise (the plugin's Edit-mode preview) this module
-- draws all of it itself, with its own copy of Draw.
local function parallel(): boolean
	return RunService:IsRunning() and RunService:IsClient() and not parent:IsA("Camera")
end

local function startWorkers()
	if #workers > 0 or not parallel() then
		return
	end
	local template = script.Parent:FindFirstChild("Worker")
	if not template then
		return
	end
	published = SharedTable.new({ Frame = 0, Build = 0 })
	for i = 1, WORKERS do
		local actor = Instance.new("Actor")
		actor.Name = `OceanWorker{i}`
		actor.Archivable = false
		local worker = template:Clone()
		worker.Parent = actor
		actor.Parent = parent
		workers[i] = actor
	end
end

local function stopWorkers()
	for _, actor in workers do
		actor:Destroy()
	end
	table.clear(workers)
	table.clear(workerBuild)
	published = nil
end

-- Hands the current build to every worker that is ready and doesn't have it yet (with the client's
-- setting overrides, so its waves match).
local function loadWorkers()
	local d, shared = drawData, published
	if not (d and shared) then
		return
	end
	for i, actor in workers do
		if workerBuild[actor] ~= d.Build and actor:GetAttribute("Ready") then
			workerBuild[actor] = d.Build
			for name, value in forwarded do
				actor:SendMessage("Override", script.Parent, name, value)
			end
			actor:SendMessage("Load", script.Parent, shared, i, #workers, d)
		end
	end
end

-- Adaptive quality: the frame rate, averaged over a second, decides the rung. Under TargetFPS for
-- ADAPT_DOWN_AFTER seconds steps one rung down (each drops something: the film, the foam and ripples, the
-- contact foam, then how many vertices are animated); well above it for ADAPT_UP_AFTER seconds lets the climb
-- (see nextClimb) try a rung up. The gap between the two keeps it from flapping.
local ADAPT_DOWN_AFTER = 3
local ADAPT_UP_AFTER = 12
local ADAPT_UP_RATIO = 1.35 -- a rung up needs this many times the target
local ADAPT_SETTLE = 5 -- s after a change before the frame rate counts again
local ADAPT_LOAD_GRACE = 20 -- s after the sea starts before the frame rate counts
local fpsFrames, fpsTime, fpsNow = 0, 0, 0
local lowSince: number? = nil
local highSince: number? = nil
local settleUntil = 0

local function adapt(dt: number)
	fpsFrames += 1
	fpsTime += dt
	if fpsTime < 1 then
		return
	end
	fpsNow = fpsFrames / fpsTime
	fpsFrames, fpsTime = 0, 0
	Renderer.Stats.Fps = fpsNow
	if container then
		container:SetAttribute("Fps", math.round(fpsNow))
	end

	local now = os.clock()
	if not Settings.Get("AdaptiveQuality") or parent:IsA("Camera") or building or now < settleUntil then
		lowSince, highSince = nil, nil
		return
	end
	local target = Settings.Get("TargetFPS")
	if fpsNow < target then
		highSince = nil
		lowSince = lowSince or now
		if now - lowSince >= ADAPT_DOWN_AFTER then
			lowSince = nil
			settleUntil = now + ADAPT_SETTLE
			stepDown()
		end
	elseif fpsNow >= target * ADAPT_UP_RATIO then
		lowSince = nil
		highSince = highSince or now
	else
		lowSince, highSince = nil, nil
	end
end

-- Whether the frame rate has been high enough long enough to try a finer rung
local function roomToClimb(): boolean
	if not Settings.Get("AdaptiveQuality") or parent:IsA("Camera") then
		return true
	end
	return highSince ~= nil and os.clock() - highSince >= ADAPT_UP_AFTER
end

local frameInfo = {} :: Draw.Frame -- this update's frame, for the workers or this module's own Draw

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
	if started >= nextClimb and not building and roomToClimb() then
		nextClimb = math.huge -- climb sets the next one
		highSince = nil
		settleUntil = started + ADAPT_SETTLE
		task.spawn(climb)
	end
	local d = drawData
	if not model or not d then
		return
	end
	loadWorkers()

	if seenVersion ~= Waves.Version then
		seenVersion = Waves.Version
		refreshActive() -- wavelengths may have changed which vertices can move
		staticDone, coloredOnce = false, false
	end

	local view = camera.CFrame
	local focus = view.Position
	local ox = math.round(focus.X / snap) * snap
	local oz = math.round(focus.Z / snap) * snap
	local moved = ox ~= lastOx or oz ~= lastOz
	local prevOx, prevOz = lastOx, lastOz
	lastOx, lastOz = ox, oz
	local seaLevel = Waves.SeaLevel
	if seaLevel ~= lastSeaLevel then -- only SeaLevel moves the skinned parts; the re-centre is in the bones
		lastSeaLevel = seaLevel
		for _, p in tileParts do
			p.CFrame = CFrame.new(0, seaLevel, 0)
		end
		if foamPart then
			foamPart.CFrame = CFrame.new(0, seaLevel + FOAM_LIFT, 0)
		end
		for _, p in filmParts do
			p.CFrame = CFrame.new(0, seaLevel + FILM_LIFT, 0)
		end
		if staticPart and not moved then
			staticPart.CFrame = CFrame.new(ox, seaLevel, oz)
		end
	end

	local now = workspace:GetServerTimeNow()
	local zones = Waves.ZonesNear(ox, oz, animatedRadius * 1.5)
	Renderer.Stats.Layers = if #zones > 0 then -#zones else Waves.Gather(zones, ox, oz, now)
	local night = if Settings.Get("DynamicLighting") then nightFactor() else 1
	if math.abs(night - seenNight) > 0.01 then
		seenNight = night
		recolour(night)
	end
	staticTimer += period
	local refresh = moved or staticTimer >= STATIC_REFRESH
	if refresh then
		staticTimer = 0
	end
	-- a dry box near the mesh is cut every frame (whoever draws finds the boxes itself)
	Regions.Sync()
	local cutting = false
	for _, box in Regions.Near(ox, oz, animatedRadius * 1.5) do
		if box.Top > seaLevel and box.Bottom < seaLevel + Waves.MaxAmp then
			cutting = true
			break
		end
	end

	frame += 1
	flatSea = Settings.Get("FlatSea") == true
	-- StaticWaves (or a flat sea): after one full pass nothing moves until the mesh re-centres or
	-- the waves change. DynamicColors off: foam is written once the same way.
	if (flatSea or Settings.Get("StaticWaves")) and staticDone and not moved and not cutting then
		return -- (a dry box nearby may be moving: its cut is redrawn every frame)
	end
	local colorPass = moved or (frame % quality.ColorEvery == 0 and (Settings.Get("DynamicColors") or not coloredOnce))
	-- Near vertices every frame; the coarser LOD ring at a lower rate, all of it on the same frames
	-- (staggering neighbours onto different frames shows as corrugation at grazing angles).
	-- The mesh just re-centred: every vertex must be placed against the new origin THIS frame, or the
	-- half-rate ring sits a tile off for a frame (the "chop" when moving fast).
	local farPass = moved or frame % quality.FarEvery == 0
	-- a re-centre of a few tiles eases in from the old surface; a jump (teleport, rebuild) does not
	local morph = false
	if moved then
		morph = math.abs(ox - prevOx) <= 4 * snap and math.abs(oz - prevOz) <= 4 * snap
		morphStart = if morph then started else -math.huge
	end

	local right, up, look = view.RightVector, view.UpVector, view.LookVector
	local tanV = math.tan(math.rad(camera.FieldOfView) / 2)
	local viewport = camera.ViewportSize
	local tanH = tanV * viewport.X / math.max(viewport.Y, 1)
	local p = frameInfo
	p.Build, p.Frame, p.Ox, p.Oz, p.Moved, p.Morph = d.Build, frame, ox, oz, moved, morph
	p.ShiftX, p.ShiftZ = if morph then ox - prevOx else 0, if morph then oz - prevOz else 0
	p.Easing = math.max(1 - (started - morphStart) / MORPH_TIME, 0)
	p.T, p.Now, p.SeaLevel, p.Flat, p.Shading = Waves.Time(), now, seaLevel, flatSea, Settings.Get("WaveShading")
	p.FarPass, p.ColorPass, p.Refresh, p.Radius, p.Night = farPass, colorPass, refresh, animatedRadius, night
	p.Fx, p.Fy, p.Fz = focus.X, focus.Y, focus.Z
	p.RX, p.RY, p.RZ = right.X, right.Y, right.Z
	p.UX, p.UY, p.UZ = up.X, up.Y, up.Z
	p.KX, p.KY, p.KZ = look.X, look.Y, look.Z
	p.TanH, p.TanV, p.SecH, p.SecV = tanH, tanV, math.sqrt(1 + tanH * tanH), math.sqrt(1 + tanV * tanV)
	local frameOut = published
	local updated: number? = nil
	if frameOut then
		-- the workers draw it, in parallel, after this (the frame number last: it is what they wait on)
		for key, value in p :: any do
			if key ~= "Frame" then
				frameOut[key] = value
			end
		end
		frameOut.Frame = frame
	else
		updated = Draw.Step(p)
		Draw.Write()
	end

	if not moved then -- a re-centre frame skips the behind-camera vertices; the next full pass counts
		staticDone = true
		if colorPass then
			coloredOnce = true
		end
	end
	-- the main thread's cost: this, and the workers' writes (their maths runs in parallel: DrawMs)
	local writes, slowest = 0, 0
	for _, actor in workers do
		writes += actor:GetAttribute("WriteMs") or 0
		slowest = math.max(slowest, actor:GetAttribute("StepMs") or 0)
	end
	Renderer.Stats.UpdateMs = (os.clock() - started) * 1000 + writes
	Renderer.Stats.DrawMs = slowest
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
		model:SetAttribute("Workers", #workers)
		model:SetAttribute("DrawMs", math.round(slowest * 100) / 100)
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
	Contact.Init(parent)
	startWorkers() -- before the first build, which then goes to them
	connection = Settings.OnChanged(function(name)
		-- a client-local override (a zone's look) goes to the workers' own Settings too
		local override = Settings.LocalOverride(name)
		if override ~= forwarded[name] then
			forwarded[name] = override
			for _, actor in workers do
				actor:SendMessage("Override", script.Parent, name, override)
			end
		end
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
			if wantFilm() ~= (#filmParts > 0) and container then
				task.spawn(build) -- the film comes in from 0, or goes at 0
			end
			for _, p in filmParts do
				p.Transparency = 1 - Settings.Get("FilmOpacity")
			end
		elseif name == "NightBrightness" or name == "DeepColor" or name == "ShallowColor" then
			seenNight = -1
		end
	end)
	task.spawn(build)
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, update)
	settleUntil = os.clock() + ADAPT_LOAD_GRACE -- the first seconds are load, not the steady frame rate
	adaptConnection = RunService.PreRender:Connect(adapt)
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
	if adaptConnection then
		adaptConnection:Disconnect()
		adaptConnection = nil
	end
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if placeholderAdded then
		placeholderAdded:Disconnect()
		placeholderAdded = nil
	end
	destroyMesh()
	stopWorkers()
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
	for _, effect in { blurEffect, focusEffect } do
		effect:Destroy()
	end
	blurEffect, focusEffect, underwaterMix = nil, nil, 0
	SurfaceTexture.Stop()
	SurfaceDetail.Stop()
	Contact.Stop()
	Spectral.StopRender()
end

return Renderer

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
	measurable. So the animated lattice is cut into blocks of BLOCK cells with the camera at a
	block CORNER: the 2500-bone disc (radius ~28 cells) lands in exactly four tiles of at most
	33 x 33 vertices, and every vertex no wave can reach (the outer ring, the horizon skirt)
	lives in ONE plain mesh with no bones at all. Tiles share their border vertices (duplicated,
	same rest position, same displacement), so there are no cracks. All of it sits under a Model
	named OceanSurface that carries the stats attributes.

	Budget: a client may hold only ~8 EditableMesh / EditableImage objects, whatever their size.
	4 tiles + static + foam + film = 7 leaves one for the foam's animated image. When even that
	is refused the build steps down: no film, then no foam, then a single tile.

	LOD: the grid is uniform (CellSize) for InnerCells around the camera, then every cell outward
	is Growth x bigger, and the last one stretches to RenderDistance. Each wave is faded out on
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
	        colours are white, so the tint and the night darkening never touch the mesh). Lit, so
	        the skinned normals give the crests and troughs their shading.
	  foam: a coarse near-camera lattice (2 x CellSize, InnerCells wide) with the animated
	        foam-ring texture; per-vertex ALPHA is the foam amount. Its alpha has to be written,
	        and a write to a SKINNED mesh is ~6x the cost of one to a plain mesh, so this one is
	        NOT skinned: it is its own small plain mesh whose 400-odd positions and alphas are
	        written outright (about 1 ms), never the base.
	  film: the same coarse lattice, skinned, a translucent skin in the water's own colour at
	        FilmOpacity, so anything crossing the surface gets a clear waterline.
	Nothing writes to a skinned mesh after it is built: the textures tile by a multiple of the
	cell and the mesh re-centres by that tile, so the UVs never need to move either.
	Vertex alpha is only honoured on parts with Transparency > 0, hence FOAM_TRANSPARENCY; the base
	stays at exactly 0 (opaque = depth-sorted properly, no seeing far waves through near ones).
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
local MAX_BONES = 2500
local BLOCK = 32 -- lattice cells per tile side: the camera sits at a block corner, so the bone disc is 4 tiles

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
local gridN = 0
-- the foam lattice: FINE spacing over the inner half of the full-detail area (coarser and the base
-- pokes through between its vertices), one plain mesh. Index f.
local foamX: { number } = {}
local foamZ: { number } = {}
local foamIds: { number } = {}
local foamColorIds: { number } = {}
local foamFade: { number } = {} -- foam vertex -> 1 inside, easing to 0 over the outer third
-- the film: a coarse lattice (2 x fine cell) over the full-detail area, skinned and tiled. Index j.
local filmBones: { Bone } = {}
local filmX: { number } = {}
local filmZ: { number } = {}
local lastSeaLevel = math.huge -- the parts' height last written
local foamAlphas: { number } = {} -- last alpha written per foam vertex
local foamKeys: { number } = {} -- quantised colour last written per foam vertex
local foamDamp: { number? } = {} -- foam vertex -> obstacle damp, nil = open water
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
local staticTimer = 0
local staticDone = false -- StaticWaves: one full position pass has been written since the last change
local coloredOnce = false -- DynamicColors off: one colour pass has been written
local nextUpdate = 0 -- os.clock() of the next mesh update (UpdateRate throttle)
local frame = 0
local lastOx, lastOz = math.huge, math.huge
local tile = 32 -- studs per texture repeat: TILE_CELLS fine cells
local snap = 32 -- studs the mesh re-centres by: the texture tile, so the textures stay put in the world
-- Continuous LOD: the fade of each wave depends on distance from the TRUE camera position, via
-- the grid's own spacing law spacing(d) = cell + (d - innerRadius) * (growth - 1) / growth, not on
-- which ring a vertex happens to sit in, so re-centring the mesh never changes a wave's weight.
local lodCell, lodInner, lodSlope = 8, 0, 0
local animatedRadius = 0
-- The skin set is the nearest MAX_BONES lattice points, a disc; past its edge vertices rest flat on
-- Root. Every wave fades to nothing over the outer part of that disc, so the edge never shows.
local skinFade: { number } = {} -- vertex -> 0..1 multiplier on its displacement
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
	tile = qCell * TILE_CELLS
	snap = tile
	SurfaceTexture.SetSmooth(quality.SmoothFoam)
end

local function buildAxis(): ({ number }, { number })
	local cell, inner, outer = qCell, qInner, qOuter
	local growth = Settings.Get("Growth")

	local half = { 0 } -- coordinates from the centre outward
	local sizes = {} -- sizes[i] = cell between half[i] and half[i + 1]
	local size = cell
	for i = 1, inner + outer do
		if i > inner then
			size *= growth
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

-- WaterMaterial by name: an Enum.Material or a MaterialVariant in MaterialService (returned as the
-- second value with its base); an unknown name lands on the closest (prefix / substring), else the default.
local function materialFor(name: string): (Enum.Material, string)
	local wanted = tostring(name or ""):lower()
	for _, variant in game:GetService("MaterialService"):GetChildren() do
		if variant:IsA("MaterialVariant") and variant.Name:lower() == wanted then
			return variant.BaseMaterial, variant.Name
		end
	end
	local items = Enum.Material:GetEnumItems()
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
		base.Transparency = 0 -- opaque: depth-sorted exactly
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

-- Which vertices any wave can still move (near: fine lattice, far: LOD ring): those get their
-- Bone instance; the rest (and the vertices past the skin budget) stand still at rest on Root.
-- The rule is per lattice point, so both copies of a shared border vertex agree.
local function refreshActive()
	if not container then
		return
	end
	table.clear(near)
	table.clear(far)
	animatedRadius = 0
	local fine = 1 / (3 * qCell) - 1e-9
	local active = 0
	for v = 1, #baseX do
		local bone = bones[v]
		-- a wave still moves this vertex if wavelength * invSpacing - 1 > 0
		if hasSkin[v] and Waves.MaxLength * invSpacing[v] > 1 then
			active += 1
			if not bone then
				bone = Instance.new("Bone")
				bone.Name = tostring(localOf[v])
				bone.Position = Vector3.new(baseX[v], 0, baseZ[v])
				bone.Parent = partOf[v]
				bones[v] = bone
			end
			if invSpacing[v] >= fine then
				table.insert(near, v)
			else
				table.insert(far, v)
			end
			animatedRadius = math.max(animatedRadius, math.abs(baseX[v]), math.abs(baseZ[v]))
		elseif bone then
			bone:Destroy()
			bones[v] = nil
		end
	end
	Renderer.Stats.Active = active
	Renderer.Stats.Bones = #near + #far + #filmBones
	seenNight = -1 -- recolour
end

-- The plugin's flat placeholder water is hidden (locally) while the wave mesh runs, and left
-- showing when the sea is flat: then it IS the sea.
local hiddenPlaceholders: { [BasePart]: number } = {}

local function hidePlaceholders()
	for _, placeholder in CollectionService:GetTagged(PLACEHOLDER_TAG) do
		if placeholder:IsA("BasePart") and hiddenPlaceholders[placeholder] == nil then
			hiddenPlaceholders[placeholder] = placeholder.LocalTransparencyModifier
			placeholder.LocalTransparencyModifier = 1 -- local only: the saved part is untouched
		end
	end
end

local function showPlaceholders()
	for placeholder, modifier in hiddenPlaceholders do
		if placeholder.Parent then
			placeholder.LocalTransparencyModifier = modifier
		end
	end
	table.clear(hiddenPlaceholders)
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
	table.clear(foamFade)
end

-- The block a lattice CELL (1 .. n - 1, spanning vertices c .. c + 1) belongs to. The centre
-- vertex m is a block corner, so the bone disc around the camera is split in four.
-- `budgetLevel` rises when the client's EditableMesh budget refuses the meshes: 1 = no film,
-- 2 = no foam either, 3 = one tile for everything.
local budgetLevel = 0
local pendingMeshes: { EditableMesh } = {} -- created by the build in progress, destroyed if it fails

local function blockOf(c: number, m: number): number
	local size = if budgetLevel >= 3 then 4 * MAX_CELLS_PER_SIDE else BLOCK
	return (c - m) // size
end

-- A mesh over a set of lattice cells: UVs tiled in world studs, an optional colour per vertex, and
-- a skin bone (named by the vertex's index in THIS mesh) on the lattice points in `skin` (all of
-- them when true, none when false; a table is indexed by lattice point). A skinned mesh drops any
-- vertex with no bone, so with a table the rest ride one "Root" bone. Vertices are emitted lazily,
-- so a tile (a rectangle of cells) and the static mesh (any set) share this. Returns the mesh, the
-- lattice point of each emitted vertex, the vertex ids, the colour ids, and the creation shrink
-- (< 1 when the mesh is wider than the 2048-stud creation cap; the caller restores the real
-- positions after CreateMeshPartAsync).
local function latticeMesh(
	coords: { number },
	cells: { number },
	n: number,
	withColors: boolean,
	skin: { boolean? } | boolean
): (EditableMesh, { number }, { number }, { number }, number)
	local em = AssetService:CreateEditableMesh()
	if not em then
		error("EditableMesh memory budget reached")
	end
	table.insert(pendingMeshes, em)
	local verts, vids, cids, uvs = {}, {}, {}, {}
	local emitted: { [number]: number } = {} -- lattice point -> emitted index
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
	local coords, space = buildAxis()
	lodCell = qCell
	lodInner = qCell * qInner
	local growth = Settings.Get("Growth")
	lodSlope = (growth - 1) / growth
	local n = #coords
	local m = (n + 1) // 2 -- the centre vertex (coords[m] == 0)

	-- The skin set, per lattice point: the nearest points first until MAX_BONES is spent. A point on
	-- a block border exists in two (or four) tiles and needs a bone in each, so it costs that many.
	local byDistance = {}
	for zi = 1, n do
		for xi = 1, n do
			table.insert(byDistance, (zi - 1) * n + xi)
		end
	end
	table.sort(byDistance, function(a, b)
		local ax, az = coords[(a - 1) % n + 1], coords[(a - 1) // n + 1]
		local bx, bz = coords[(b - 1) % n + 1], coords[(b - 1) // n + 1]
		return ax * ax + az * az < bx * bx + bz * bz
	end)
	local function onBorder(i: number): boolean -- vertex i is shared by cells i - 1 and i in different blocks
		return i > 1 and i < n and blockOf(i - 1, m) ~= blockOf(i, m)
	end
	local skinL: { boolean? } = {}
	local spent = 0
	for _, L in byDistance do
		local xi, zi = (L - 1) % n + 1, (L - 1) // n + 1
		local cost = (if onBorder(xi) then 2 else 1) * (if onBorder(zi) then 2 else 1)
		if spent + cost > MAX_BONES then
			break
		end
		spent += cost
		skinL[L] = true
	end

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
			latticeMesh(coords, cellsOf[key], n, false, skinL)
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
	-- film: the coarse lattice over the whole full-detail area, skinned and tiled like the base
	local coarse = {}
	for c = -lodInner, lodInner + 1e-3, 2 * qCell do
		table.insert(coarse, c)
	end
	local cn = #coarse
	-- one mesh: at most 625 vertices, and every mesh counts against the client's budget
	local newFilmMeshes, filmVerts = {}, {}
	if quality.Film and Settings.Get("Highlights") and budgetLevel < 1 then
		local allCoarse = {}
		for c = 1, (cn - 1) * (cn - 1) do
			table.insert(allCoarse, c)
		end
		local sm, verts, _, colors = latticeMesh(coarse, allCoarse, cn, true, true)
		local fadeStart = lodInner * 0.6
		-- alpha fades out over the outer third so the edge never shows
		for k, L in verts do
			local edge = math.max(math.abs(coarse[(L - 1) % cn + 1]), math.abs(coarse[(L - 1) // cn + 1]))
			local t = math.clamp((edge - fadeStart) / (lodInner - fadeStart), 0, 1)
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
	local foamEdge = lodInner / 2
	local foamFadeStart = foamEdge * 0.6
	for f, L in foamVerts do
		local x, z = fineHalf[(L - 1) % fn + 1], fineHalf[(L - 1) // fn + 1]
		foamX[f], foamZ[f] = x, z
		-- fades out over the outer third so the foam's edge never shows
		local t = math.clamp((math.max(math.abs(x), math.abs(z)) - foamFadeStart) / (foamEdge - foamFadeStart), 0, 1)
		foamFade[f] = 1 - t * t * (3 - 2 * t)
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
	local fadeFrom = skinRadius * 0.7
	table.clear(skinFade)
	for v = 1, #baseX do
		local d = math.sqrt(baseX[v] * baseX[v] + baseZ[v] * baseZ[v])
		local t = math.clamp((d - fadeFrom) / math.max(skinRadius - fadeFrom, 1), 0, 1)
		skinFade[v] = 1 - t * t * (3 - 2 * t)
	end
	gridN = n
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

local function build()
	buildToken += 1
	local token = buildToken

	if not Waves.MeshAvailable() then
		-- no wave mesh without EditableMesh access: the flat water slab stays as the sea
		showPlaceholders()
		if not warnedNoMesh then
			warnedNoMesh = true
			warn(
				"[Ocean] EditableMesh is not enabled for this experience (Experience Settings): the sea is flat. Enable it for the dynamic sea."
			)
		end
		return
	end
	hidePlaceholders()
	while true do
		table.clear(pendingMeshes)
		local ok, err = pcall(buildOnce, token)
		if ok then
			table.clear(pendingMeshes) -- owned now
			return
		end
		for _, em in pendingMeshes do
			em:Destroy()
		end
		table.clear(pendingMeshes)
		if budgetLevel >= 3 then -- already down to one tile and nothing else
			warn(`[Ocean] the sea could not be built: {err}`)
			return
		end
		budgetLevel += 1
		warn(`[Ocean] {err}: retrying with fewer meshes (level {budgetLevel}: no film, no foam, one tile)`)
	end
end

-- Recompute the per-vertex static fields for the mesh centred at (ox, oz): obstacle damping,
-- dry-region pins and the shove-clamp candidates.
local function refreshStatic(ox: number, oz: number)
	table.clear(pinned)
	table.clear(dampOf)
	table.clear(nearDry)
	table.clear(foamDamp)
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
	end
	dryNear = Regions.Near(ox, oz, animatedRadius * 1.5)
	local boxes = Regions.List()
	if #boxes == 0 then
		return
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
		and focus.Y < Waves.Height(focus.X, focus.Z)
		and not Regions.IsDry(focus)
	if tint.Visible ~= under then
		tint.Visible = under
	end
	if under then
		local color, transparency = Settings.Get("UnderwaterTint"), 1 - Settings.Get("UnderwaterOpacity")
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
local function waveAt(wx: number, wz: number, inv: number, t: number): (number, number, number)
	if flatSea then -- FlatSea: the same sea, its surface level (the tiles rest at zero displacement)
		return 0, 0, 0
	end
	local sets, weights = Waves.LayerSets, Waves.LayerWeights
	local cos, sin = math.cos, math.sin
	local dx, dy, dz = 0, 0, 0
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
				dx += dirX[w] * c
				dz += dirZ[w] * c
				dy += sin(f) * a
			end
		end
	end
	return dx, dy, dz
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
		for _, root in roots do
			root.Transform = CFrame.new(ox, 0, oz)
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
	local nightKey = floor(night * 100) * 4096
	local fineInv = 1 / (3 * lodCell)

	frame += 1
	flatSea = Settings.Get("FlatSea") == true
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
			local inv = 1 / (3 * (lodCell + math.max(math.sqrt(ddx * ddx + ddz * ddz) - lodInner, 0) * lodSlope))
			gatherAt(wx, wz)
			local dx, dy, dz = waveAt(wx, wz, inv, t)
			local fade = skinFade[v]
			if fade < 1 then
				dx, dy, dz = dx * fade, dy * fade, dz * fade
			end
			local damp = dampOf[v]
			if damp then
				dx, dy, dz = dx * damp, dy * damp, dz * damp
			end
			local pin = pinned[v]
			if pin then
				-- inside a dry region: sunk under its floor (a box above the water leaves it alone)
				dx, dz = pin[1], pin[2]
				dy = math.min(dy, pin[3] - seaLevel)
			elseif nearDry[v] then
				-- outside, but the Gerstner shove would carry it in: clamp to the wall
				for _, box in dryNear do
					local cx, cz, shoved = Regions.PushOut(box, wx + dx, wz + dz)
					if shoved then
						dx, dz = cx - wx, cz - wz
						break
					end
				end
			end
			local bone = bones[v] :: Bone
			bone.Transform = CFrame.new(ox + dx, dy, oz + dz)
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
				dx, dy, dz = dx * damp, dy * damp, dz * damp
				shore = damp * (1 - damp) * 4 -- peaks halfway across the ring: the "breaking" line
			end
			fm:SetPosition(foamIds[f], Vector3.new(wx + dx, dy, wz + dz))
			if not colorPass then
				continue
			end
			local foam = clamp((dy / lookMaxAmp - lookFoamStart) / math.max(lookFoamFull - lookFoamStart, 1e-3), 0, 1)
			foam = math.max(foam, shore * 0.6) -- wash against obstacles
			-- quantised to 64 steps and only written when the step changes: the mesh upload is the
			-- expensive part, and most frames nothing here changed
			local key = nightKey + floor(foam * 63) + (if sameLayers then 0 else 64 * floor(lookFoamOpacity * 63))
			if key ~= foamKeys[f] then
				foamKeys[f] = key
				fm:SetColor(foamColorIds[f], Color3.new(foamR * night, foamG * night, foamB * night))
				local alpha = (lookWebOpacity + (lookFoamOpacity - lookWebOpacity) * foam) * foamFade[f]
				if alpha ~= foamAlphas[f] then
					foamAlphas[f] = alpha
					fm:SetColorAlpha(foamColorIds[f], alpha)
				end
			end
		end
	end

	-- the film: the same waves on its own coarse lattice (bones, so nothing is written to its mesh)
	for j, bone in filmBones do
		local wx, wz = ox + filmX[j], oz + filmZ[j]
		if not behindPass and (wx - fx) * lookX + (wz - fz) * lookZ < -BEHIND_MARGIN then
			continue
		end
		gatherAt(wx, wz)
		local dx, dy, dz = waveAt(wx, wz, fineInv, t)
		bone.Transform = CFrame.new(ox + dx, dy, oz + dz)
	end

	if not moved then -- a re-centre frame skips the behind-camera vertices; the next full pass counts
		staticDone = true
		if colorPass then
			coloredOnce = true
		end
	end
	Renderer.Stats.UpdateMs = (os.clock() - started) * 1000
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
		if Waves.MeshAvailable() then
			hidePlaceholders()
		end
	end)
	connection = Settings.OnChanged(function(name)
		local entry = Settings.Spec[name]
		if entry and entry.Rebuild then
			task.spawn(build)
		elseif name == "StaticWaves" or name == "FlatSea" or name == "DynamicColors" or name == "DynamicLighting" then
			staticDone, coloredOnce = false, false
		elseif
			name == "Reflectance"
			or name == "WaterMaterial"
			or name == "WaterTexture"
			or name == "FoamTexture"
			or name == "FoamStyle"
			or name == "Lit"
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

function Renderer.Stop()
	if not running then
		return
	end
	running = false
	showPlaceholders()
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
	budgetLevel = 0
	if tintFrame then
		local gui = tintFrame.Parent
		if gui then
			gui:Destroy()
		end
		tintFrame = nil
	end
	SurfaceTexture.Stop()
end

return Renderer

--!native
--!optimize 2
--[[
	Clipmap

	Draws the FFT sea as nested LOD levels of EditableMesh tiles centred on the
	camera (a geometry clipmap). Level l has cells of BaseCellSize * 2^l studs
	and spans GridCells x GridCells cells. Level 0 is a full grid; every other
	level is a ring of 12 tiles around the level inside it.

	Geomorphing: towards the outer edge of each level, vertices with odd grid
	coordinates slide onto their even neighbour, turning the level into the
	next coarser grid. Waves are sampled at the morphed position, so where two
	levels meet their surfaces are identical: no cracks and no popping.

	Filtering: each level samples the cascade mip that matches its vertex
	spacing and blends towards the next level's mip with the same morph
	factor, so small waves fade out with distance instead of aliasing, and
	the seams still match exactly.

	Snapping: each level is centred on a multiple of twice its cell size so
	vertices never swim. Finer levels snap on finer grids, so the tiles next
	to a ring's hole extend one cell into the finer level ("fat" tiles). The
	overlap is always fully morphed, so both surfaces coincide there; the part
	of it the finer level covers is sunk a little so the two never z-fight.

	Per vertex the renderer writes position, normal, colour (water, crest, sky
	reflection and foam from a palette) and, when the surface has a
	SurfaceAppearance (the ripples' normal map), UV: one UV unit is TileSize
	studs. Tiles outside the camera frustum are skipped, and far tiles are
	split so no mesh exceeds Roblox's 2048 stud limit.

	Memory: clients have a tight EditableMesh budget, and a growable mesh
	reserves far more than it uses. Each tile is therefore a FixedSize copy
	of a shared template (one per tile shape), which costs only its actual
	vertices.

	(Part of the FFT sea, see Spectral.)
]]

local AssetService = game:GetService("AssetService")

local Masks = require(script.Parent.Masks)
local Simulation = require(script.Parent.Simulation)

local Clipmap = {}
Clipmap.__index = Clipmap

local STRIDE = 6
local FOAM_STEPS = 16
local CREST_STEPS = 8
local FRESNEL_STEPS = 8
local MAX_MESH_EXTENT = 2040
local BUILD_THREADS = 6
-- Minimum cosine between a vertex normal and the view direction
local MIN_VIEW_FACING = 0.35
-- Foam values between these map onto the palette with a smoothstep, which keeps
-- foam patches solid with short soft edges instead of a wide smear
local FOAM_EDGE_LOW = 0.08
local FOAM_EDGE_HIGH = 0.75
local MORPH_STEPS = 8
-- The ripples drift across the surface; the UVs are rewritten each time they have moved this much of a
-- texture tile (about a tenth of a stud at the default drift), which is smooth to the eye and cheap
local UV_DRIFT_STEP = 0.004

-- The LOD visualizer's colour per level; vertices that are morphing blend towards the next level's colour
local LEVEL_COLORS = {
	Color3.fromRGB(255, 85, 85),
	Color3.fromRGB(255, 170, 60),
	Color3.fromRGB(245, 235, 80),
	Color3.fromRGB(95, 225, 95),
	Color3.fromRGB(70, 200, 255),
	Color3.fromRGB(95, 110, 255),
	Color3.fromRGB(190, 95, 255),
	Color3.fromRGB(255, 95, 200),
	Color3.fromRGB(235, 235, 235),
	Color3.fromRGB(130, 130, 130),
}

export type Level = {
	index: number,
	cellSize: number,
	isLast: boolean,
	morphStart: number,
	morphScale: number,
	-- snapped centre in cells, always even
	cgx: number,
	cgz: number,
}

export type Tile = {
	level: Level,
	cx: number,
	cz: number,
	radius: number,
	count: number,
	gx: { number },
	gz: { number },
	vertexIds: { number },
	normalIds: { number },
	colorIds: { number },
	uvIds: { number },
	positions: { Vector3 },
	normals: { Vector3 },
	colors: { Color3 },
	uvs: { Vector2 },
	mesh: EditableMesh,
	part: MeshPart,
	placedX: number?,
	placedY: number?,
	placedZ: number?,
	-- part origin, snapped to the tile size; vertices are relative to it
	originX: number,
	originY: number,
	originZ: number,
	uvOriginX: number,
	uvOriginZ: number,
	uvDirty: boolean,
	-- morph factor each vertex's UV was last written with
	uvAlpha: { number },
	uvChangedIds: { number },
	uvChangedValues: { Vector2 },
	uvChanged: number,
	driftU: number,
	driftV: number,
	uvMode: number,
	cfDirty: boolean,
	writeMesh: boolean,
}

type TileSpec = {
	level: Level,
	gx0: number,
	gx1: number,
	gz0: number,
	gz1: number,
}

local function firstIds(nested: { { number } }): { number }
	local ids = table.create(#nested)
	for i, list in nested do
		ids[i] = list[1]
	end
	return ids
end

-- Splits the cell range [first, last] into pieces of at most maxCells cells
local function splitRange(first: number, last: number, maxCells: number): { { number } }
	local cells = last - first
	if cells <= maxCells then
		return { { first, last } }
	end
	local size = math.ceil(cells / math.ceil(cells / maxCells))
	local ranges = {}
	local start = first
	while start < last do
		local finish = math.min(start + size, last)
		table.insert(ranges, { start, finish })
		start = finish
	end
	return ranges
end

--[[
	Adds one mip's bilinear samples into the accumulators. mode 0 weighs every
	vertex fully, mode 1 by (1 - morph) and mode 2 by morph, which blends the
	level's own mip into the next level's mip across the morph band.
	`foamWeight` scales the foam this cascade puts into vertex colours.
]]
local function accumulate(
	mip: any,
	mode: number,
	foamWeight: number,
	count: number,
	MX: { number },
	MZ: { number },
	ALPHA: { number },
	AX: { number },
	AH: { number },
	AZ: { number },
	AGX: { number },
	AGZ: { number },
	AF: { number }
)
	local data, n = mip.data, mip.n

	if n == 1 then
		local dx, h, dz, gx, gz, foam = data[1], data[2], data[3], data[4], data[5], data[6] * foamWeight
		for k = 1, count do
			local w = if mode == 0 then 1 elseif mode == 1 then 1 - ALPHA[k] else ALPHA[k]
			if w > 0 then
				AX[k] += dx * w
				AH[k] += h * w
				AZ[k] += dz * w
				AGX[k] += gx * w
				AGZ[k] += gz * w
				AF[k] += foam * w
			end
		end
		return
	end

	local scale, offset = mip.scale, mip.offset
	for k = 1, count do
		local w = if mode == 0 then 1 elseif mode == 1 then 1 - ALPHA[k] else ALPHA[k]
		if w > 0 then
			local u, v = MX[k] * scale + offset, MZ[k] * scale + offset
			local iu, iv = math.floor(u), math.floor(v)
			local fu, fv = u - iu, v - iv
			iu %= n
			iv %= n
			local iu1 = if iu == n - 1 then 0 else iu + 1
			local row0 = iv * n
			local row1 = (if iv == n - 1 then 0 else iv + 1) * n
			local b00 = (row0 + iu) * STRIDE
			local b10 = (row0 + iu1) * STRIDE
			local b01 = (row1 + iu) * STRIDE
			local b11 = (row1 + iu1) * STRIDE
			local wu, wv = fu * w, fv * w
			local w11 = fu * wv
			local w10 = wu - w11
			local w01 = wv - w11
			local w00 = w - wu - wv + w11

			AX[k] += data[b00 + 1] * w00 + data[b10 + 1] * w10 + data[b01 + 1] * w01 + data[b11 + 1] * w11
			AH[k] += data[b00 + 2] * w00 + data[b10 + 2] * w10 + data[b01 + 2] * w01 + data[b11 + 2] * w11
			AZ[k] += data[b00 + 3] * w00 + data[b10 + 3] * w10 + data[b01 + 3] * w01 + data[b11 + 3] * w11
			AGX[k] += data[b00 + 4] * w00 + data[b10 + 4] * w10 + data[b01 + 4] * w01 + data[b11 + 4] * w11
			AGZ[k] += data[b00 + 5] * w00 + data[b10 + 5] * w10 + data[b01 + 5] * w01 + data[b11 + 5] * w11
			if foamWeight > 0 then
				AF[k] += (data[b00 + 6] * w00 + data[b10 + 6] * w10 + data[b01 + 6] * w01 + data[b11 + 6] * w11) * foamWeight
			end
		end
	end
end

function Clipmap.new(config: any, simulation: any, masks: any, parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "OceanSurface"
	folder.Parent = parent

	local self = setmetatable({
		config = config,
		simulation = simulation,
		masks = masks,
		folder = folder,
		levels = {} :: { Level },
		tiles = {} :: { Tile },
		palette = {} :: { Color3 },
		debugPalette = {} :: { { Color3 } },
		night = 1,
		cells = 0,
		verticalExtent = 40,
		horizontalMargin = 16,
		farStart = math.huge,
		farScale = 0,
		stats = { visibleTiles = 0, vertices = 0, tiles = 0, failedTiles = 0 },
		scratch = {
			mx = {},
			mz = {},
			alpha = {},
			dx = {},
			h = {},
			dz = {},
			gx = {},
			gz = {},
			foam = {},
			cut = {},
			uvIds = {},
			uvValues = {},
		},
		building = false,
		destroyed = false,
		doubleSided = false,
		textured = false,
	}, Clipmap)

	self:RebuildPalette()
	return self
end

-- The water's colours: indexed by foam, crest height and Fresnel reflection, times the night factor
function Clipmap:RebuildPalette()
	local config = self.config
	local night = self.night
	local palette = table.create(FOAM_STEPS * CREST_STEPS * FRESNEL_STEPS)
	for fi = 0, FOAM_STEPS - 1 do
		local t = math.clamp((fi / (FOAM_STEPS - 1) - FOAM_EDGE_LOW) / (FOAM_EDGE_HIGH - FOAM_EDGE_LOW), 0, 1)
		local foam = t * t * (3 - 2 * t)
		for ci = 0, CREST_STEPS - 1 do
			local crest = (ci / (CREST_STEPS - 1)) ^ 1.5 * config.CrestStrength
			local water = config.DeepColor:Lerp(config.CrestColor, crest)
			for ri = 0, FRESNEL_STEPS - 1 do
				local reflected = water:Lerp(config.SkyColor, ri / (FRESNEL_STEPS - 1) * config.SkyReflection)
				local color = reflected:Lerp(config.FoamColor, foam)
				palette[(fi * CREST_STEPS + ci) * FRESNEL_STEPS + ri + 1] =
					Color3.new(color.R * night, color.G * night, color.B * night)
			end
		end
	end
	self.palette = palette

	local debugPalette = {}
	for l = 1, #LEVEL_COLORS do
		local from, to = LEVEL_COLORS[l], LEVEL_COLORS[math.min(l + 1, #LEVEL_COLORS)]
		local steps = table.create(MORPH_STEPS)
		for m = 0, MORPH_STEPS - 1 do
			local color = from:Lerp(to, m / (MORPH_STEPS - 1))
			steps[m + 1] = Color3.new(color.R * night, color.G * night, color.B * night)
		end
		debugPalette[l] = steps
	end
	self.debugPalette = debugPalette
end

function Clipmap:SetNight(night: number)
	self.night = night
	self:RebuildPalette()
end

-- Lets the surface be seen from below (while the camera is underwater)
function Clipmap:SetDoubleSided(enabled: boolean)
	self.doubleSided = enabled
	for _, tile in self.tiles do
		tile.part.DoubleSided = enabled
	end
end

function Clipmap:ApplyMaterial()
	local config = self.config
	for _, tile in self.tiles do
		tile.part.Material = config.Material
		tile.part.Reflectance = config.Reflectance
	end
end

-- Whether vertices carry UVs (for the SurfaceAppearance's maps)
function Clipmap:SetTextured(on: boolean)
	if self.textured == on then
		return
	end
	self.textured = on
	for _, tile in self.tiles do
		tile.uvDirty = true
	end
end

function Clipmap:Parts(): { MeshPart }
	local parts = table.create(#self.tiles)
	for i, tile in self.tiles do
		parts[i] = tile.part
	end
	return parts
end

-- Forces tiles to re-place themselves (after the simulation changed patch sizes)
function Clipmap:InvalidatePlacement()
	for _, tile in self.tiles do
		tile.placedX = nil
		tile.uvDirty = true
	end
end

-- Grid topology shared by every tile with the same cell counts. Vertex
-- positions are the integer grid coordinates, which lets each copy map its
-- vertex ids back to grid cells.
local function buildTemplate(nx: number, nz: number): EditableMesh
	local mesh = AssetService:CreateEditableMesh()
	if not mesh then
		error("EditableMesh memory budget reached")
	end
	local positions = table.create((nx + 1) * (nz + 1))
	for z = 0, nz do
		for x = 0, nx do
			positions[z * (nx + 1) + x + 1] = Vector3.new(x, 0, z)
		end
	end
	local ids = mesh:BatchAdd(Enum.MeshAttribute.Vertex, positions)
	local faces = table.create(nx * nz * 2)
	for z = 0, nz - 1 do
		for x = 0, nx - 1 do
			local a = ids[z * (nx + 1) + x + 1]
			local b = ids[z * (nx + 1) + x + 2]
			local c = ids[(z + 1) * (nx + 1) + x + 1]
			local d = ids[(z + 1) * (nx + 1) + x + 2]
			-- Counter-clockwise from above, diagonal from (x, z) to (x + 1, z + 1)
			table.insert(faces, { a, c, d })
			table.insert(faces, { a, d, b })
		end
	end
	mesh:BatchAdd(Enum.MeshAttribute.Face, faces)
	return mesh
end

function Clipmap:_createTile(spec: TileSpec, template: EditableMesh): Tile
	local config = self.config
	local level = spec.level
	local S = level.cellSize
	local gx0, gx1, gz0, gz1 = spec.gx0, spec.gx1, spec.gz0, spec.gz1
	local nx, nz = gx1 - gx0, gz1 - gz0
	local halfX, halfZ = nx * S / 2, nz * S / 2
	local count = (nx + 1) * (nz + 1)

	local mesh = AssetService:CreateEditableMeshAsync(Content.fromObject(template), { FixedSize = true })
	if not mesh then
		error("EditableMesh memory budget reached")
	end

	-- Copies may number their vertices differently, so map them through the grid positions
	local copyIds = mesh:GetVertices()
	local gridPositions = mesh:BatchGetValues(copyIds)
	local vertexIds = table.create(count)
	for i, id in copyIds do
		local p = gridPositions[i]
		vertexIds[math.round(p.Z) * (nx + 1) + math.round(p.X) + 1] = id
	end

	local gxs, gzs = table.create(count), table.create(count)
	local positions = table.create(count)
	for z = 0, nz do
		for x = 0, nx do
			local k = z * (nx + 1) + x + 1
			gxs[k], gzs[k] = gx0 + x, gz0 + z
			positions[k] = Vector3.new((x - nx / 2) * S, 0, (z - nz / 2) * S)
		end
	end

	-- Two stretched corners make the part's box cover displaced and morphing vertices,
	-- so the engine never culls a tile whose waves are still on screen. The part
	-- sits up to half a tile off the tile's centre (see Update), and the box
	-- spans whole tiles.
	local period = config.TileSize
	local margin = S + self.horizontalMargin + period / 2
	local extentX = math.ceil((halfX + margin) / period) * period
	local extentZ = math.ceil((halfZ + margin) / period) * period
	local height = math.ceil(self.verticalExtent / period) * period
	positions[1] = Vector3.new(-extentX, height, -extentZ)
	positions[count] = Vector3.new(extentX, -height, extentZ)
	mesh:BatchSetValues(vertexIds, positions)

	-- Adjacent faces share attribute ids, so each vertex has exactly one of each
	local normalIds = firstIds(mesh:BatchGetVertexAttributes(Enum.MeshAttribute.Normal, vertexIds))
	local colorIds = firstIds(mesh:BatchGetVertexAttributes(Enum.MeshAttribute.Color, vertexIds))
	local uvIds = firstIds(mesh:BatchGetVertexAttributes(Enum.MeshAttribute.UV, vertexIds))

	local part = AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
		CollisionFidelity = Enum.CollisionFidelity.Box,
		RenderFidelity = Enum.RenderFidelity.Precise,
	})

	positions[1] = Vector3.new(-halfX, 0, -halfZ)
	positions[count] = Vector3.new(halfX, 0, halfZ)
	mesh:BatchSetValues(vertexIds, positions)

	part.Name = `Level{level.index}`
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Color = Color3.new(1, 1, 1)
	part.Material = config.Material
	part.Reflectance = config.Reflectance
	part.CFrame = CFrame.new(0, config.SeaLevel - 10000, 0)
	part.DoubleSided = self.doubleSided
	part.Parent = self.folder

	return {
		level = level,
		cx = (gx0 + gx1) / 2,
		cz = (gz0 + gz1) / 2,
		-- Bounding circle of the undisplaced tile; Update pads it for the waves
		radius = math.sqrt(halfX * halfX + halfZ * halfZ),
		count = count,
		gx = gxs,
		gz = gzs,
		vertexIds = vertexIds,
		normalIds = normalIds,
		colorIds = colorIds,
		uvIds = uvIds,
		positions = positions,
		normals = table.create(count, Vector3.yAxis),
		colors = table.create(count, Color3.new(1, 1, 1)),
		uvs = table.create(count, Vector2.zero),
		mesh = mesh,
		part = part,
		placedX = nil,
		placedY = nil,
		placedZ = nil,
		originX = 0,
		originY = 0,
		originZ = 0,
		uvOriginX = 0,
		uvOriginZ = 0,
		uvDirty = true,
		uvAlpha = table.create(count, -1),
		uvChangedIds = {},
		uvChangedValues = {},
		uvChanged = 0,
		driftU = 0,
		driftV = 0,
		uvMode = 0,
		cfDirty = false,
		writeMesh = false,
	}
end

function Clipmap:_destroyTiles()
	for _, tile in self.tiles do
		tile.part:Destroy()
		tile.mesh:Destroy()
	end
	table.clear(self.tiles)
	self.stats.tiles = 0
end

-- (Re)builds every LOD level. Yields while the meshes are created.
function Clipmap:Build()
	self.building = true
	self:_destroyTiles()

	local config = self.config
	local cells = math.max(16, 4 * math.round(config.GridCells / 4))
	local tileCells = cells // 4
	local half = cells // 2
	local quarter = cells // 4
	local levelCount = math.max(1, math.floor(config.LevelCount))

	self.cells = cells
	self.verticalExtent = math.max(40, config.WaveHeight * 3)
	self.horizontalMargin = math.max(16, config.WaveHeight * 2)

	local levels = {}
	local specs: { TileSpec } = {}
	for l = 0, levelCount - 1 do
		local cellSize = config.BaseCellSize * 2 ^ l
		local isLast = l == levelCount - 1

		-- Fully coarse before the next ring can overlap this level (its hole is one
		-- cell smaller and both levels snap up to one cell apart), and untouched
		-- where this ring overlaps the finer level inside it.
		local morphEnd = (half - 4) * cellSize
		local morphStart = math.min((quarter + 1) * cellSize, morphEnd - cellSize)

		local level: Level = {
			index = l,
			cellSize = cellSize,
			isLast = isLast,
			morphStart = if isLast then math.huge else morphStart,
			morphScale = if isLast then 0 else 1 / (morphEnd - morphStart),
			cgx = 0,
			cgz = 0,
		}
		levels[l + 1] = level

		local margin = cellSize + self.horizontalMargin
		local maxCells = math.max(1, math.floor((MAX_MESH_EXTENT - 2 * margin) / cellSize))
		for tz = 0, 3 do
			for tx = 0, 3 do
				local innerX, innerZ = tx == 1 or tx == 2, tz == 1 or tz == 2
				if l > 0 and innerX and innerZ then
					continue -- the finer level fills the middle
				end
				local gx0, gx1 = -half + tx * tileCells, -half + (tx + 1) * tileCells
				local gz0, gz1 = -half + tz * tileCells, -half + (tz + 1) * tileCells
				if l > 0 then
					if innerX and tz == 0 then
						gz1 += 1
					elseif innerX and tz == 3 then
						gz0 -= 1
					end
					if innerZ and tx == 0 then
						gx1 += 1
					elseif innerZ and tx == 3 then
						gx0 -= 1
					end
				end
				for _, xRange in splitRange(gx0, gx1, maxCells) do
					for _, zRange in splitRange(gz0, gz1, maxCells) do
						table.insert(specs, {
							level = level,
							gx0 = xRange[1],
							gx1 = xRange[2],
							gz0 = zRange[1],
							gz1 = zRange[2],
						})
					end
				end
			end
		end
	end
	self.levels = levels

	-- The outermost level flattens towards its rim
	local last = levels[#levels]
	local farEnd = (half - 3) * last.cellSize
	self.farStart = farEnd * 0.55
	self.farScale = 1 / (farEnd - self.farStart)

	-- One template per tile shape; every tile is a fixed-size copy of it
	local groups: { { nx: number, nz: number, indices: { number } } } = {}
	local groupByShape = {}
	for index, spec in specs do
		local nx, nz = spec.gx1 - spec.gx0, spec.gz1 - spec.gz0
		local key = `{nx}x{nz}`
		local group = groupByShape[key]
		if not group then
			group = { nx = nx, nz = nz, indices = {} }
			groupByShape[key] = group
			table.insert(groups, group)
		end
		table.insert(group.indices, index)
	end

	local built = table.create(#specs)
	local failed = 0
	local firstError = nil
	for _, group in groups do
		if self.destroyed then
			break
		end
		local ok, template = pcall(buildTemplate, group.nx, group.nz)
		if not ok then
			failed += #group.indices
			firstError = firstError or template
			continue
		end

		-- Copying and CreateMeshPartAsync both yield, so work on a few threads at once
		local cursor = 0
		local running = BUILD_THREADS
		for _ = 1, BUILD_THREADS do
			task.spawn(function()
				while not self.destroyed do
					cursor += 1
					local index = group.indices[cursor]
					if not index then
						break
					end
					local tileOk, result = pcall(self._createTile, self, specs[index], template)
					if tileOk then
						built[index] = result
					else
						failed += 1
						firstError = firstError or result
					end
				end
				running -= 1
			end)
		end
		while running > 0 do
			task.wait()
		end
		template:Destroy()
	end

	local tiles = {}
	for index = 1, #specs do
		local tile = built[index]
		if tile then
			table.insert(tiles, tile)
		end
	end
	self.tiles = tiles
	self.stats.tiles = #tiles
	self.stats.failedTiles = failed
	if failed > 0 then
		warn(`[Ocean] {failed} of {#specs} FFT tiles could not be built: {firstError}`)
	end

	if self.destroyed then
		self:_destroyTiles()
		return
	end

	self.building = false
end

-- Snaps the tile's part origin to the tile grid (vertices are written relative to it). The part moves
-- when the writes are applied (an Instance cannot change in parallel).
local function placeOrigin(tile: Tile, wx: number, wz: number, sea: number, period: number)
	local ox = math.round(wx / period) * period
	local oz = math.round(wz / period) * period
	if ox ~= tile.originX or oz ~= tile.originZ or sea ~= tile.originY then
		tile.originX, tile.originY, tile.originZ = ox, sea, oz
		tile.cfDirty = true
	end
end

--[[
	What a frame needs of the camera and the look, as plain numbers (so a worker Actor can read them
	from a SharedTable): CamX/Y/Z, LookX/Y/Z, RightX/Y/Z, UpX/Y/Z, TanY, ViewX, ViewY, Night, Textured, LOD.
]]
export type Frame = { [string]: any }

function Clipmap:Configure(p: Frame)
	if p.Textured ~= self.textured then
		self.textured = p.Textured
		for _, tile in self.tiles do
			tile.uvDirty = true -- the UVs are written in full when the surface first needs them
		end
	end
	self.config.ShowLODColors = p.LOD
	-- The ripples' drift: the texture slides along the flow direction at Flow studs a second, as a fraction
	-- of one texture tile (it repeats, so only the fraction matters)
	-- (the wrap is taken last: wrapping the distance first would jump the texture whenever it came round)
	local scroll = (p.Flow or 0) * (p.FlowTime or 0) / self.config.TileSize
	self.driftU, self.driftV = math.cos(p.FlowAngle or 0) * scroll % 1, math.sin(p.FlowAngle or 0) * scroll % 1
	if math.abs(p.Night - self.night) > 0.01 then
		self.night = p.Night
		self:RebuildPalette()
	end
end

--[[
	The maths of a frame for every `shares`-th tile starting at `share`: placement, culling, the waves at
	every vertex, colours and UVs. Touches no Instance, so a worker Actor runs it in parallel. Returns the
	tiles with something to write; WriteTiles applies it (on the main thread of that Actor).
]]
function Clipmap:UpdateTiles(p: Frame, share: number, shares: number): { Tile }
	local list = {}
	if self.building or self.destroyed then
		return list
	end

	local config = self.config
	local period = config.TileSize
	local camX, camY, camZ = p.CamX, p.CamY, p.CamZ
	local sea = config.SeaLevel

	local lookX, lookY, lookZ = p.LookX, p.LookY, p.LookZ
	local rightX, rightY, rightZ = p.RightX, p.RightY, p.RightZ
	local upX, upY, upZ = p.UpX, p.UpY, p.UpZ
	local tanY = p.TanY
	local tanX = tanY * p.ViewX / math.max(p.ViewY, 1)
	local normX = 1 / math.sqrt(1 + tanX * tanX)
	local normY = 1 / math.sqrt(1 + tanY * tanY)

	for _, level in self.levels do
		local twoCells = level.cellSize * 2
		level.cgx = math.round(camX / twoCells) * 2
		level.cgz = math.round(camZ / twoCells) * 2
	end

	-- UVs: TileSize studs per unit, so the SurfaceAppearance's maps have a fixed size in the world
	self.uvScale = 1 / period

	-- Waves reach roughly one wave height up and sideways from the flat tile
	local pad = config.WaveHeight * 1.3 + 2
	local visibleTiles, vertices = 0, 0

	for index, tile in self.tiles do
		if (index - 1) % shares ~= share - 1 then
			continue
		end
		local level = tile.level
		local S = level.cellSize
		local wx = (level.cgx + tile.cx) * S
		local wz = (level.cgz + tile.cz) * S
		local driftU, driftV = self.driftU or 0, self.driftV or 0
		if math.abs(driftU - tile.driftU) > UV_DRIFT_STEP or math.abs(driftV - tile.driftV) > UV_DRIFT_STEP then
			tile.uvDirty = true -- the ripples have drifted a little: every UV moves with them
		end
		if wx ~= tile.placedX or wz ~= tile.placedZ or sea ~= tile.placedY then
			tile.placedX, tile.placedY, tile.placedZ = wx, sea, wz
			-- Move every tile that changed place, visible or not, so none is left
			-- drawing where it used to be
			placeOrigin(tile, wx, wz, sea, period)
			-- Whole tiles keep the texture continuous between tiles
			tile.uvOriginX = math.floor(wx / period) * period
			tile.uvOriginZ = math.floor(wz / period) * period
			tile.uvDirty = true
		end

		-- Sphere against the view frustum
		local dx, dy, dz = wx - camX, sea - camY, wz - camZ
		local radius = tile.radius + pad
		local depth = dx * lookX + dy * lookY + dz * lookZ
		local visible = depth >= -radius
		if visible then
			local side = dx * rightX + dy * rightY + dz * rightZ
			if (depth * tanX - math.abs(side)) * normX < -radius then
				visible = false
			end
		end
		if visible then
			local vertical = dx * upX + dy * upY + dz * upZ
			if (depth * tanY - math.abs(vertical)) * normY < -radius then
				visible = false
			end
		end

		if visible then
			local nearest = math.sqrt(dx * dx + dz * dz) - tile.radius
			self:_computeTile(tile, camX, camY, camZ, sea, nearest)
			visibleTiles += 1
			vertices += tile.count
		end
		if visible or tile.cfDirty then
			table.insert(list, tile)
		end
	end

	self.stats.visibleTiles = visibleTiles
	self.stats.vertices = vertices
	return list
end

-- Applies what UpdateTiles worked out: moves the parts and writes the meshes. Serial.
function Clipmap:WriteTiles(list: { Tile })
	for _, tile in list do
		if tile.cfDirty then
			tile.cfDirty = false
			tile.part.CFrame = CFrame.new(tile.originX, tile.originY, tile.originZ)
		end
		if tile.writeMesh then
			tile.writeMesh = false
			local mesh = tile.mesh
			mesh:BatchSetValues(tile.vertexIds, tile.positions)
			mesh:BatchSetValues(tile.normalIds, tile.normals)
			mesh:BatchSetValues(tile.colorIds, tile.colors)
			if tile.uvMode == 1 then
				mesh:BatchSetValues(tile.uvIds, tile.uvs)
			elseif tile.uvMode == 2 and tile.uvChanged > 0 then
				local ids, values = tile.uvChangedIds, tile.uvChangedValues
				-- the lists are reused: trim what an earlier, longer update left past the count
				for k = #ids, tile.uvChanged + 1, -1 do
					ids[k], values[k] = nil, nil
				end
				mesh:BatchSetValues(ids, values)
			end
		end
	end
end

-- The whole frame on this thread: the maths, then the writes.
function Clipmap:Update(camera: Camera)
	local cf = camera.CFrame
	local look, right, up = cf.LookVector, cf.RightVector, cf.UpVector
	local viewport = camera.ViewportSize
	local p = self.frameScratch
	if not p then
		p = {}
		self.frameScratch = p
	end
	p.CamX, p.CamY, p.CamZ = cf.X, cf.Y, cf.Z
	p.LookX, p.LookY, p.LookZ = look.X, look.Y, look.Z
	p.RightX, p.RightY, p.RightZ = right.X, right.Y, right.Z
	p.UpX, p.UpY, p.UpZ = up.X, up.Y, up.Z
	p.TanY = math.tan(math.rad(camera.FieldOfView) * 0.5)
	p.ViewX, p.ViewY = viewport.X, viewport.Y
	p.Night, p.Textured, p.LOD = self.night, self.textured, self.config.ShowLODColors == true
	p.Flow, p.FlowAngle, p.FlowTime = self.flow, self.flowAngle, self.flowTime
	self:Configure(p)
	self:WriteTiles(self:UpdateTiles(p, 1, 1))
end

function Clipmap:_computeTile(tile: Tile, camX: number, camY: number, camZ: number, sea: number, nearest: number)
	local config = self.config
	local level = tile.level
	local S = level.cellSize
	local cgx, cgz = level.cgx, level.cgz
	local morphStart, morphScale = level.morphStart, level.morphScale
	local count = tile.count
	local gxs, gzs = tile.gx, tile.gz

	local scratch = self.scratch
	local MX, MZ, ALPHA = scratch.mx, scratch.mz, scratch.alpha
	local AX, AH, AZ = scratch.dx, scratch.h, scratch.dz
	local AGX, AGZ, AF = scratch.gx, scratch.gz, scratch.foam

	-- 1. Geomorph: near the outer edge, odd vertices slide onto their even neighbour
	for k = 1, count do
		local GX, GZ = cgx + gxs[k], cgz + gzs[k]
		local x, z = GX * S, GZ * S
		local alpha = 0
		if morphScale > 0 then
			local ax, az = x - camX, z - camZ
			if ax < 0 then
				ax = -ax
			end
			if az < 0 then
				az = -az
			end
			alpha = ((if ax > az then ax else az) - morphStart) * morphScale
			if alpha > 0 then
				if alpha > 1 then
					alpha = 1
				end
				if GX % 2 ~= 0 then
					x -= alpha * S
				end
				if GZ % 2 ~= 0 then
					z -= alpha * S
				end
			else
				alpha = 0
			end
		end
		MX[k], MZ[k], ALPHA[k] = x, z, alpha
		AX[k], AH[k], AZ[k], AGX[k], AGZ[k], AF[k] = 0, 0, 0, 0, 0, 0
	end

	-- 2. Sum the cascades from the mips matching this level's vertex spacing
	local nextLevel = self.levels[level.index + 2]
	local bias = config.MipBias
	for _, cascade in self.simulation.cascades do
		local mips = cascade.mips
		local foamWeight = cascade.settings.VertexFoam or 1
		local own = Simulation.mipFor(cascade, S, bias)
		local coarser = if nextLevel then Simulation.mipFor(cascade, nextLevel.cellSize, bias) else own
		if own == coarser then
			accumulate(mips[own], 0, foamWeight, count, MX, MZ, ALPHA, AX, AH, AZ, AGX, AGZ, AF)
		else
			accumulate(mips[own], 1, foamWeight, count, MX, MZ, ALPHA, AX, AH, AZ, AGX, AGZ, AF)
			accumulate(mips[coarser], 2, foamWeight, count, MX, MZ, ALPHA, AX, AH, AZ, AGX, AGZ, AF)
		end
	end

	-- 3. Masks: calm areas, extra foam, cutouts
	local masks = self.masks
	local CUT = scratch.cut
	local hasMasks = false
	if masks.count > 0 then
		local wx, wz, reach = tile.placedX :: number, tile.placedZ :: number, tile.radius
		local list, found = masks:Query(wx - reach, wz - reach, wx + reach, wz + reach)
		if found > 0 then
			hasMasks = true
			local evaluate = Masks.evaluate
			for k = 1, count do
				local amplitude, foam, cut = evaluate(list, found, MX[k], sea, MZ[k])
				if amplitude < 1 then
					AX[k] *= amplitude
					AH[k] *= amplitude
					AZ[k] *= amplitude
					AGX[k] *= amplitude
					AGZ[k] *= amplitude
					AF[k] *= amplitude
				end
				AF[k] += foam
				CUT[k] = cut - sea
			end
		end
	end

	-- 4. Vertex attributes
	-- The finer level covers part of this level's fat tiles. Vertices strictly
	-- inside its rim sink below it so the finer surface always wins the depth
	-- test; the rim itself stays put, so no gap opens where the levels meet.
	local finer = self.levels[level.index]
	local coverHalf, coverX, coverZ, coverSink = -1, 0, 0, 0
	if finer then
		local fs = finer.cellSize
		coverHalf = (self.cells / 2) * fs - fs * 0.01
		coverX, coverZ = finer.cgx * fs, finer.cgz * fs
		coverSink = fs * 0.5
	end

	local positions, normals, colors, uvs = tile.positions, tile.normals, tile.colors, tile.uvs
	local ox, oz = tile.originX, tile.originZ
	local farStart, farScale = self.farStart, self.farScale
	local fadesOut = nearest + 2 * tile.radius > farStart
	local palette = self.palette
	local debugColors = if config.ShowLODColors
		then self.debugPalette[math.min(level.index + 1, #self.debugPalette)]
		else nil
	local waveHeight = math.max(config.WaveHeight, 0.01)
	local crestLow = waveHeight * 0.1
	local crestScale = (CREST_STEPS - 1) / (waveHeight * 0.55)
	local foamScale = config.FoamStrength * (FOAM_STEPS - 1)
	local textured = self.textured
	local uvScale = self.uvScale
	local uvX, uvZ = tile.uvOriginX, tile.uvOriginZ

	for k = 1, count do
		local x, z = MX[k], MZ[k]
		local dx, h, dz = AX[k], AH[k], AZ[k]
		local gx, gz, foam = AGX[k], AGZ[k], AF[k]

		if fadesOut then
			local ax, az = x - camX, z - camZ
			if ax < 0 then
				ax = -ax
			end
			if az < 0 then
				az = -az
			end
			local over = (if ax > az then ax else az) - farStart
			if over > 0 then
				local s = 1 - over * farScale
				if s < 0 then
					s = 0
				end
				dx *= s
				h *= s
				dz *= s
				gx *= s
				gz *= s
				foam *= s
			end
		end

		local y = h
		if hasMasks then
			local cut = CUT[k]
			if cut < y then
				y = cut
			end
		end
		local px, pz = x + dx, z + dz
		local drawY = y
		if coverHalf > 0 then
			local rx, rz = x - coverX, z - coverZ
			if rx > -coverHalf and rx < coverHalf and rz > -coverHalf and rz < coverHalf then
				drawY -= coverSink
			end
		end
		positions[k] = Vector3.new(px - ox, drawY, pz - oz)

		-- Normals at grazing angles reflect the grey lower half of the sky and leave
		-- dirty rims on crests, so tilt them towards the viewer.
		local nx, ny, nz = gx, 1, gz
		local facing = 1
		local vx, vy, vz = camX - px, camY - sea - y, camZ - pz
		local viewLength = math.sqrt(vx * vx + vy * vy + vz * vz)
		if viewLength > 1e-3 then
			vx, vy, vz = vx / viewLength, vy / viewLength, vz / viewLength
			local normalLength = math.sqrt(nx * nx + 1 + nz * nz)
			facing = (nx * vx + ny * vy + nz * vz) / normalLength
			if facing < MIN_VIEW_FACING then
				local push = (MIN_VIEW_FACING - facing) * normalLength
				nx += vx * push
				ny += vy * push
				nz += vz * push
			end
		end
		local invLength = 1 / math.sqrt(nx * nx + ny * ny + nz * nz)
		normals[k] = Vector3.new(nx * invLength, ny * invLength, nz * invLength)

		local ci = (h - crestLow) * crestScale
		ci = if ci <= 0 then 0 elseif ci >= CREST_STEPS - 1 then CREST_STEPS - 1 else math.floor(ci + 0.5)
		local fi = foam * foamScale
		fi = if fi <= 0 then 0 elseif fi >= FOAM_STEPS - 1 then FOAM_STEPS - 1 else math.floor(fi + 0.5)
		-- Schlick Fresnel from the unclamped normal: the flatter the view, the more sky
		local grazing = if facing > 0 then 1 - facing else 1
		local grazing2 = grazing * grazing
		local ri = math.floor(grazing2 * grazing2 * grazing * (FRESNEL_STEPS - 1) + 0.5)
		if debugColors then
			colors[k] = debugColors[math.floor(ALPHA[k] * (MORPH_STEPS - 1) + 0.5) + 1]
		else
			colors[k] = palette[(fi * CREST_STEPS + ci) * FRESNEL_STEPS + ri + 1]
		end
	end

	-- The vertex data is in the tile's arrays; WriteTiles puts it in the mesh.
	tile.writeMesh = true

	-- UVs follow the morphed grid (the collapsed vertices are what form the coarse
	-- triangles), but they only change with the tile's placement or a vertex's
	-- morph factor, so only those vertices are rewritten.
	tile.uvMode = 0
	if textured then
		local uvAlpha = tile.uvAlpha
		if tile.uvDirty then
			tile.uvDirty = false
			tile.uvMode = 1
			-- the drift as it is now (the UVs of the partial update below keep the drift they were written with)
			tile.driftU, tile.driftV = self.driftU or 0, self.driftV or 0
			local driftU, driftV = tile.driftU, tile.driftV
			for k = 1, count do
				uvAlpha[k] = ALPHA[k]
				uvs[k] = Vector2.new((MX[k] - uvX) * uvScale - driftU, (MZ[k] - uvZ) * uvScale - driftV)
			end
		else
			local changedIds, changedValues = tile.uvChangedIds, tile.uvChangedValues
			local driftU, driftV = tile.driftU, tile.driftV
			local uvIds = tile.uvIds
			local changed = 0
			for k = 1, count do
				local alpha = ALPHA[k]
				if alpha ~= uvAlpha[k] then
					uvAlpha[k] = alpha
					changed += 1
					changedIds[changed] = uvIds[k]
					changedValues[changed] =
						Vector2.new((MX[k] - uvX) * uvScale - driftU, (MZ[k] - uvZ) * uvScale - driftV)
				end
			end
			tile.uvMode = 2
			tile.uvChanged = changed
		end
	end
end

--[[
	Handing the tiles to worker Actors (Spectral.Worker). Export gives the plain data every worker
	needs; ExportTile the fixed part of one tile (its meshes and vertex ids); forShare rebuilds a
	Clipmap inside the Actor from those, holding only its share of the tiles. The Actor then calls
	Configure / UpdateTiles / WriteTiles each frame like the main thread would.
]]
function Clipmap:Export(): any
	local levels = table.create(#self.levels)
	for i, level in self.levels do
		levels[i] = {
			index = level.index,
			cellSize = level.cellSize,
			isLast = level.isLast,
			morphStart = level.morphStart,
			morphScale = level.morphScale,
			cgx = 0,
			cgz = 0,
		}
	end
	local config = {}
	for key, value in self.config do
		if typeof(value) ~= "EnumItem" then
			config[key] = value
		end
	end
	return {
		config = config,
		levels = levels,
		cells = self.cells,
		farStart = self.farStart,
		farScale = self.farScale,
		verticalExtent = self.verticalExtent,
		horizontalMargin = self.horizontalMargin,
	}
end

function Clipmap:ExportTile(tile: Tile): any
	return {
		levelIndex = tile.level.index,
		cx = tile.cx,
		cz = tile.cz,
		radius = tile.radius,
		count = tile.count,
		gx = tile.gx,
		gz = tile.gz,
		vertexIds = tile.vertexIds,
		normalIds = tile.normalIds,
		colorIds = tile.colorIds,
		uvIds = tile.uvIds,
		mesh = tile.mesh,
		part = tile.part,
	}
end

function Clipmap.forShare(state: any, simulation: any, masks: any, records: { any }): any
	local self = setmetatable({
		config = state.config,
		simulation = simulation,
		masks = masks,
		levels = state.levels,
		tiles = {},
		palette = {},
		debugPalette = {},
		night = 1,
		cells = state.cells,
		verticalExtent = state.verticalExtent,
		horizontalMargin = state.horizontalMargin,
		farStart = state.farStart,
		farScale = state.farScale,
		stats = { visibleTiles = 0, vertices = 0, tiles = #records, failedTiles = 0 },
		scratch = {
			mx = {},
			mz = {},
			alpha = {},
			dx = {},
			h = {},
			dz = {},
			gx = {},
			gz = {},
			foam = {},
			cut = {},
		},
		building = false,
		destroyed = false,
		doubleSided = false,
		textured = false,
	}, Clipmap)

	for i, record in records do
		local count = record.count
		self.tiles[i] = {
			level = self.levels[record.levelIndex + 1],
			cx = record.cx,
			cz = record.cz,
			radius = record.radius,
			count = count,
			gx = record.gx,
			gz = record.gz,
			vertexIds = record.vertexIds,
			normalIds = record.normalIds,
			colorIds = record.colorIds,
			uvIds = record.uvIds,
			positions = table.create(count, Vector3.zero),
			normals = table.create(count, Vector3.yAxis),
			colors = table.create(count, Color3.new(1, 1, 1)),
			uvs = table.create(count, Vector2.zero),
			mesh = record.mesh,
			part = record.part,
			placedX = nil,
			placedY = nil,
			placedZ = nil,
			originX = 0,
			originY = 0,
			originZ = 0,
			uvOriginX = 0,
			uvOriginZ = 0,
			uvDirty = true,
			uvAlpha = table.create(count, -1),
			uvChangedIds = {},
			uvChangedValues = {},
			uvChanged = 0,
			driftU = 0,
			driftV = 0,
			uvMode = 0,
			cfDirty = false,
			writeMesh = false,
		}
	end
	self:RebuildPalette()
	return self
end

function Clipmap:Destroy()
	self.destroyed = true
	self:_destroyTiles()
	self.folder:Destroy()
end

return Clipmap

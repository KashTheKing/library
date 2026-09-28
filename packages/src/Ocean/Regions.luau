--[[
	Dry regions: tag a BasePart or Model "OceanDry" and there is no water inside it - where the box
	crosses the water line the surface mesh is cut out of it at its walls (Regions.Cut), the underwater tint stays off for a camera inside it, characters don't
	swim in it and the water events treat it as air. Submarine interiors, underwater rooms, diving bells.

	Shared by both sides (visuals, swim, events, buoyancy, the IsUnderWater API). A float inside a
	dry region gets no lift - unless the region belongs to it (same model or welded assembly), so a
	submarine's hull still floats around its own interior while cargo inside it does not.

	The tagged instances are re-read twice a second; where each box is follows its part every frame
	(Regions.Sync), so the dry region of a moving ship stays exactly where the ship is.
]]
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)

--[=[
	@class Regions

	Dry regions: tag a BasePart or Model `OceanDry` and there is no water inside its box. Where the box
	crosses the water line the surface is cut out of it at its walls, the underwater tint stays off for a camera inside, characters do not swim there and
	water events treat it as air. Submarine interiors, underwater rooms, diving bells.

	A float inside a dry region gets no lift unless the region belongs to it (same model or welded
	assembly), so a submarine's hull floats while cargo inside it does not.
]=]
--[=[
	@interface Box
	@within Regions
	.CFrame CFrame
	.Half Vector3 -- half size
	.X number
	.Z number
	.Reach number -- bounding radius in XZ
	.Bottom number -- world Y
	.Top number -- world Y
	.Instance Instance -- the tagged part or model
	.Model Model? -- the model it belongs to, if any
	.Owner BasePart? -- the assembly it is welded into, if any
]=]
local Regions = {}

export type Box = {
	CFrame: CFrame,
	Half: Vector3,
	X: number,
	Z: number,
	Reach: number,
	Bottom: number,
	Top: number,
	Instance: Instance, -- the tagged part/model
	Model: Model?, -- the model it belongs to (a vehicle), if any
	Owner: BasePart?, -- the assembly it is welded into, if any
	Anchor: BasePart?, -- the part the box moves with
	Offset: CFrame, -- the box relative to its anchor
}

local boxes: { Box } = {}
local timer = 0
local CUT_EDGE = 0.05 -- studs outside the wall the cut is drawn: seen from inside, the wall hides it
local CUT_SINK = 0.5 -- studs under the box's bottom the surface inside it runs (no z-fighting with its floor)
local CUT_SNAP, CUT_BAND = 2, 3.5 -- in cells: outside points this near go onto the wall, then ease back out
local CUT_CORNER, CUT_CORNER_BAND = 2.5, 4 -- in cells: wall points this near a corner go to it, then ease back
local connection: RBXScriptConnection? = nil

-- The world extents that follow from a box's CFrame: vertical span and XZ reach of the rotated box.
local function place(box: Box, cframe: CFrame)
	local half = box.Half
	local right, up, look = cframe.RightVector, cframe.UpVector, cframe.LookVector
	local ey = math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z
	local ex = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z
	local ez = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
	box.CFrame = cframe
	box.X, box.Z = cframe.Position.X, cframe.Position.Z
	box.Reach = math.sqrt(ex * ex + ez * ez)
	box.Bottom, box.Top = cframe.Position.Y - ey, cframe.Position.Y + ey
end

--[=[
	@within Regions
	Re-reads every `OceanDry` instance. Runs twice a second on its own.
]=]
function Regions.Refresh()
	table.clear(boxes)
	for _, instance in CollectionService:GetTagged(Settings.Get("DryTag")) do
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
		local model = if instance:IsA("Model") then instance else instance:FindFirstAncestorOfClass("Model")
		local anchor = if instance:IsA("BasePart")
			then instance
			else (instance :: Model).PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
		local box = {
			Half = size / 2,
			Instance = instance,
			Model = model,
			Owner = if anchor then anchor.AssemblyRootPart else nil,
			Anchor = anchor,
			Offset = if anchor then anchor.CFrame:ToObjectSpace(cframe) else cframe,
		} :: any
		place(box, cframe)
		table.insert(boxes, box)
	end
end

--[=[
	@within Regions
	Moves every box to where its part is now. Cheap (a CFrame per box); runs every frame on its own,
	and the renderer calls it before drawing so the water is cut where the box is this frame.
]=]
function Regions.Sync()
	for _, box in boxes do
		local anchor = box.Anchor
		if anchor then
			place(box, anchor.CFrame * box.Offset)
		end
	end
end

--[=[
	@within Regions
	Every dry box.
	@return { Box }
]=]
function Regions.List(): { Box }
	return boxes
end

-- Boxes whose XZ footprint touches the circle (x, z, radius).
--[=[
	@within Regions
	Dry boxes whose footprint touches the circle `(x, z, radius)`.
	@param x number
	@param z number
	@param radius number
	@return { Box }
]=]
function Regions.Near(x: number, z: number, radius: number): { Box }
	local near = {}
	for _, box in boxes do
		local dx, dz = box.X - x, box.Z - z
		local reach = box.Reach + radius + 64 -- + the widest cell that may still touch the box
		if dx * dx + dz * dz < reach * reach then
			table.insert(near, box)
		end
	end
	return near
end

local function inside(box: Box, point: Vector3): boolean
	local l = box.CFrame:PointToObjectSpace(point)
	local h = box.Half
	return math.abs(l.X) <= h.X and math.abs(l.Y) <= h.Y and math.abs(l.Z) <= h.Z
end

--[=[
	@within Regions
	True inside any dry box. [Ocean:IsDry] calls this.
	@param point Vector3
	@return boolean
]=]
function Regions.IsDry(point: Vector3): boolean
	for _, box in boxes do
		if inside(box, point) then
			return true
		end
	end
	return false
end

-- A vehicle's own hull sits inside its own dry interior, so the region must not dry ITS parts:
-- anything in the same model, or welded into the same assembly, ignores that region.
local function exempt(box: Box, instance: Instance): boolean
	if instance == box.Instance then
		return true
	end
	if box.Model and (instance == box.Model or instance:IsDescendantOf(box.Model)) then
		return true
	end
	return box.Owner ~= nil and instance:IsA("BasePart") and instance.AssemblyRootPart == box.Owner
end

-- IsDry for a specific part/model: crates inside a submarine are dry, the submarine itself is not.
--[=[
	@within Regions
	Like [Regions.IsDry], but a box that belongs to `instance` (its own model or welded assembly) does not count.
	@param point Vector3
	@param instance Instance
	@return boolean
]=]
function Regions.IsDryFor(point: Vector3, instance: Instance): boolean
	for _, box in boxes do
		if not exempt(box, instance) and inside(box, point) then
			return true
		end
	end
	return false
end

-- Ignoring height: is the column above/below (x, z) within `margin` studs of this box's footprint?
--[=[
	@within Regions
	True when `(x, z)` is within the box's footprint, grown by `margin` studs.
	@param box Box
	@param x number
	@param z number
	@param margin number?
	@return boolean
]=]
function Regions.CoversXZ(box: Box, x: number, z: number, margin: number?): boolean
	local l = box.CFrame:PointToObjectSpace(Vector3.new(x, box.CFrame.Position.Y, z))
	local m = margin or 0
	return math.abs(l.X) <= box.Half.X + m and math.abs(l.Z) <= box.Half.Z + m
end

-- If (x, z) is inside the footprint, push it out to the nearest wall. Returns x, z, wasInside.
--[=[
	@within Regions
	The nearest point on the box's footprint edge to `(x, z)`, and whether the point was inside.
	@param box Box
	@param x number
	@param z number
	@return number -- x
	@return number -- z
	@return boolean -- was inside
]=]
function Regions.PushOut(box: Box, x: number, z: number): (number, number, boolean)
	local cf, h = box.CFrame, box.Half
	local l = cf:PointToObjectSpace(Vector3.new(x, cf.Position.Y, z))
	if math.abs(l.X) > h.X or math.abs(l.Z) > h.Z then
		return x, z, false
	end
	local lx, lz = l.X, l.Z
	if h.X - math.abs(l.X) < h.Z - math.abs(l.Z) then
		lx = if l.X < 0 then -h.X else h.X
	else
		lz = if l.Z < 0 then -h.Z else h.Z
	end
	local w = cf:PointToWorldSpace(Vector3.new(lx, 0, lz))
	return w.X, w.Z, true
end

local depths: { number } = {} -- scratch for Regions.Cut: per box, how far inside it the point is

-- Slides a coordinate a (-h .. h along a piece of outline) toward the piece's nearer end: within
-- pullTo of it, it is the end (a corner of the outline), eased back to where it was at pullBand.
-- On a piece too short for that both scale down, so its middle stays put and nothing jumps.
local function toCorner(a: number, h: number, pullTo: number, pullBand: number): number
	local reachEnd = math.min(pullBand, h)
	local toEnd = h - math.abs(a)
	if toEnd >= reachEnd then
		return a
	end
	local at = pullTo * reachEnd / pullBand
	local kept = if toEnd > at then (toEnd - at) * reachEnd / (reachEnd - at) else 0
	return if a < 0 then kept - h else h - kept
end

--[=[
	@within Regions
	@interface Outline
	.Planes { number } -- per box, its four walls as inward normal x, z and offset (12 numbers)
	.Sinks { number } -- per box, the height the surface inside it is drawn at, at most
	.Pieces { number } -- the outline of all the boxes together: per segment its start x, z, its run x, z, 1 / length squared, length and box
	.MinX number
	.MaxX number
	.MinZ number
	.MaxZ number
]=]
export type Outline = {
	Planes: { number },
	Sinks: { number },
	Pieces: { number },
	MinX: number,
	MaxX: number,
	MinZ: number,
	MaxZ: number,
}

--[=[
	@within Regions
	The dry boxes in `list` cut through the horizontal plane at `level` (the water line), together:
	each box's footprint there, and the outline of all of them, less the walls one box hides inside
	another. [Regions.Cut] draws the surface against it.
	@param list { Box }
	@param level number
	@return Outline
]=]
function Regions.Outline(list: { Box }, level: number): Outline
	local planes, sinks, quads = {}, {}, {}
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for i, box in list do
		local cframe = box.CFrame
		local o, right, up, back = cframe.Position, cframe.XVector, cframe.YVector, cframe.ZVector
		local hx, hz = box.Half.X + CUT_EDGE, box.Half.Z + CUT_EDGE
		local quad = {}
		for k, corner in { { -hx, -hz }, { hx, -hz }, { hx, hz }, { -hx, hz } } do
			local lx, lz = corner[1], corner[2]
			local ly = (level - o.Y - right.Y * lx - back.Y * lz) / up.Y -- on the water line
			local x = o.X + right.X * lx + up.X * ly + back.X * lz
			local z = o.Z + right.Z * lx + up.Z * ly + back.Z * lz
			quad[2 * k - 1], quad[2 * k] = x, z
			minX, maxX, minZ, maxZ = math.min(minX, x), math.max(maxX, x), math.min(minZ, z), math.max(maxZ, z)
		end
		-- which way round the corners go
		local turn = (quad[3] - quad[1]) * (quad[6] - quad[2]) - (quad[4] - quad[2]) * (quad[5] - quad[1])
		local side = if turn > 0 then 1 else -1
		for k = 0, 3 do
			local ax, az = quad[2 * k + 1], quad[2 * k + 2]
			local bx, bz = quad[(2 * k + 2) % 8 + 1], quad[(2 * k + 3) % 8 + 1]
			local dx, dz = bx - ax, bz - az
			local len = math.sqrt(dx * dx + dz * dz)
			local nx, nz = -dz / len * side, dx / len * side -- inward
			table.insert(planes, nx)
			table.insert(planes, nz)
			table.insert(planes, nx * ax + nz * az)
		end
		sinks[i] = box.Bottom - CUT_SINK
		quads[i] = quad
	end
	-- each wall, less the parts inside another box (grown a hair, so two walls that touch both go)
	local pieces = {}
	for i, quad in quads do
		for k = 0, 3 do
			local ax, az = quad[2 * k + 1], quad[2 * k + 2]
			local bx, bz = quad[(2 * k + 2) % 8 + 1], quad[(2 * k + 3) % 8 + 1]
			local kept = { 0, 1 } -- the spans of the wall (0 at a, 1 at b) still on the outline
			for j = 1, #quads do
				if j == i then
					continue
				end
				local enter, leave = 0, 1
				for w = 0, 3 do
					local o = 12 * (j - 1) + 3 * w
					local nx, nz, c = planes[o + 1], planes[o + 2], planes[o + 3]
					local f0, f1 = nx * ax + nz * az - c + CUT_EDGE, nx * bx + nz * bz - c + CUT_EDGE
					if f0 < 0 and f1 < 0 then
						enter, leave = 1, 0
						break
					elseif f0 < 0 then
						enter = math.max(enter, f0 / (f0 - f1))
					elseif f1 < 0 then
						leave = math.min(leave, f0 / (f0 - f1))
					end
				end
				if enter < leave then
					local rest = {}
					for q = 1, #kept, 2 do
						local s0, s1 = kept[q], kept[q + 1]
						if s0 < enter then
							table.insert(rest, s0)
							table.insert(rest, math.min(s1, enter))
						end
						if s1 > leave then
							table.insert(rest, math.max(s0, leave))
							table.insert(rest, s1)
						end
					end
					kept = rest
				end
			end
			for q = 1, #kept, 2 do
				local s0, s1 = kept[q], kept[q + 1]
				if (s1 - s0) * math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2) > 1e-3 then
					local dx, dz = (bx - ax) * (s1 - s0), (bz - az) * (s1 - s0)
					local len2 = dx * dx + dz * dz
					table.insert(pieces, ax + (bx - ax) * s0)
					table.insert(pieces, az + (bz - az) * s0)
					table.insert(pieces, dx)
					table.insert(pieces, dz)
					table.insert(pieces, 1 / len2)
					table.insert(pieces, math.sqrt(len2))
					table.insert(pieces, i)
				end
			end
		end
	end
	return { Planes = planes, Sinks = sinks, Pieces = pieces, MinX = minX, MaxX = maxX, MinZ = minZ, MaxZ = maxZ }
end

--[=[
	@within Regions
	Where a point of a lattice surface (spacing `cell`) is drawn so that none of the surface is inside
	the outline's boxes. A point inside goes out to the nearest point of the outline and down under
	its box; a point outside within 2 cells goes onto the outline at its own height, and from there
	to 3.5 cells out eases back to where it was. Near a corner of the outline, points on it slide
	into the corner. So every triangle that crosses the outline has its corners on one wall: the
	water meets the wall at the water line and hangs straight down it, with none inside and no dip
	outside. Continuous in the point and the boxes, so a moving box cuts smoothly.
	@param outline Outline
	@param x number
	@param y number
	@param z number
	@param cell number
	@return number -- x
	@return number -- y
	@return number -- z
]=]
function Regions.Cut(outline: Outline, x: number, y: number, z: number, cell: number): (number, number, number)
	local snapTo, band = CUT_SNAP * cell, CUT_BAND * cell
	if x < outline.MinX - band or x > outline.MaxX + band or z < outline.MinZ - band or z > outline.MaxZ + band then
		return x, y, z
	end
	-- per box, how far inside its nearest wall the point is (negative outside: then the point is at
	-- least that far from the box). Inside a box, the surface sinks under the lowest box it is in.
	local planes, sink, near = outline.Planes, math.huge, false
	for i, level in outline.Sinks do
		local o = 12 * (i - 1)
		local depth = math.min(
			planes[o + 1] * x + planes[o + 2] * z - planes[o + 3],
			planes[o + 4] * x + planes[o + 5] * z - planes[o + 6],
			planes[o + 7] * x + planes[o + 8] * z - planes[o + 9],
			planes[o + 10] * x + planes[o + 11] * z - planes[o + 12]
		)
		depths[i] = depth
		if depth > 0 then
			sink = math.min(sink, level)
		end
		near = near or depth > -band
	end
	if not near then
		return x, y, z
	end
	-- the nearest point of the outline (a box farther off than the best so far can't hold it)
	local pieces = outline.Pieces
	local best, at, along, length = band * band, 0, 0, 0
	if sink < math.huge then
		best = math.huge
	end
	for i = 1, #pieces, 7 do
		local depth = depths[pieces[i + 6]]
		if depth < 0 and depth * depth >= best then
			continue
		end
		local ax, az, dx, dz = pieces[i], pieces[i + 1], pieces[i + 2], pieces[i + 3]
		local s = math.clamp(((x - ax) * dx + (z - az) * dz) * pieces[i + 4], 0, 1)
		local ex, ez = x - ax - dx * s, z - az - dz * s
		local d2 = ex * ex + ez * ez
		if d2 < best then
			best, at, along, length = d2, i, s, pieces[i + 5]
		end
	end
	if at == 0 then
		return x, y, z
	end
	local d = math.sqrt(best)
	local dry = sink < math.huge
	-- slid along its piece toward the nearer corner
	local half = length / 2
	local s = (toCorner(along * length - half, half, CUT_CORNER * cell, CUT_CORNER_BAND * cell) + half) / length
	local ax, az = pieces[at], pieces[at + 1]
	local qx, qz = ax + pieces[at + 2] * s, az + pieces[at + 3] * s
	if dry then
		return qx, math.min(y, sink), qz
	end
	local u = if d > snapTo then (d - snapTo) * band / ((band - snapTo) * d) else 0
	return qx + (x - qx) * u, y, qz + (z - qz) * u
end

--[=[
	@within Regions
	@private
]=]
function Regions.Init()
	if connection then
		return
	end
	Regions.Refresh()
	connection = RunService.Heartbeat:Connect(function(dt)
		timer += dt
		if timer >= 0.5 then
			timer = 0
			Regions.Refresh()
		else
			Regions.Sync()
		end
	end)
end

--[=[
	@within Regions
	@private
]=]
function Regions.Stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

return Regions

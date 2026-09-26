--[[
	Dry regions: tag a BasePart or Model "OceanDry" and there is no water inside it - the surface
	mesh sinks under the box, the underwater tint stays off for a camera inside it, characters don't
	swim in it and the water events treat it as air. Submarine interiors, underwater rooms, diving bells.

	Shared by both sides (visuals, swim, events, buoyancy, the IsUnderWater API). A float inside a
	dry region gets no lift - unless the region belongs to it (same model or welded assembly), so a
	submarine's hull still floats around its own interior while cargo inside it does not.
]]
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)

--[=[
	@class Regions

	Dry regions: tag a BasePart or Model `OceanDry` and there is no water inside its box. The surface
	sinks under it, the underwater tint stays off for a camera inside, characters do not swim there and
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
}

local boxes: { Box } = {}
local timer = 0
local connection: RBXScriptConnection? = nil

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
		local half = size / 2
		-- world-space vertical extent and XZ reach of the rotated box
		local right, up, look = cframe.RightVector, cframe.UpVector, cframe.LookVector
		local ey = math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z
		local ex = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z
		local ez = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
		local model = if instance:IsA("Model") then instance else instance:FindFirstAncestorOfClass("Model")
		local anchor = if instance:IsA("BasePart") then instance else (instance :: Model).PrimaryPart
		table.insert(boxes, {
			CFrame = cframe,
			Half = half,
			X = cframe.Position.X,
			Z = cframe.Position.Z,
			Reach = math.sqrt(ex * ex + ez * ez),
			Bottom = cframe.Position.Y - ey,
			Top = cframe.Position.Y + ey,
			Instance = instance,
			Model = model,
			Owner = if anchor then anchor.AssemblyRootPart else nil,
		})
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

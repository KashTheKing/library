--!native
--!optimize 2
--[[
	Masks

	Parts and models that reshape the FFT sea around them. Three tags feed it:

		OceanDry (the DryTag)        Cutout: the water is pushed below the box, so it never shows inside
		OceanObstacle (ObstacleTag)  Calm: the waves flatten around it (the Gerstner sea's shore)
		OceanMask                    any of the modes below, chosen with the Mode attribute

	Attributes on a tagged part or model:

		Mode      string   "Calm" flattens the waves inside, "Cutout" pushes the water below the box
		                   (boat hulls, caves), "Foam" adds foam around it (rocks, piers).
		Shape     string   "Box" or "Ellipse". Ball and Cylinder parts default to "Ellipse".
		Falloff   number   width of the soft edge in studs (Cutout ignores it).
		Strength  number   0..1 (default 1). An obstacle also reads OceanShore / OceanCalmness.

	The footprint is the cross-section at sea level, measured along the box's two most horizontal
	axes, so rotated and moving parts work. Masks are usually invisible parts (Transparency 1,
	CanCollide off).

	(Part of the FFT sea, see Spectral.)
]]

local CollectionService = game:GetService("CollectionService")

local Masks = {}
Masks.__index = Masks

local MODE_CALM = 1
local MODE_CUTOUT = 2
local MODE_FOAM = 3

local MODES = {
	Calm = MODE_CALM,
	Cutout = MODE_CUTOUT,
	Foam = MODE_FOAM,
}

export type Source = { Tag: string, Mode: string, Falloff: number, Strength: number? }

export type Record = {
	mode: number,
	ellipse: boolean,
	falloff: number,
	strength: number,
	cx: number,
	cy: number,
	cz: number,
	-- the two horizontal axes of the footprint and their half sizes
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number,
	ha: number,
	hb: number,
	bottom: number,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

function Masks.new(sources: { Source })
	local self = setmetatable({
		instances = {} :: { [Instance]: Source },
		autoParts = {} :: { [Instance]: boolean }, -- parts foaming where they cross the water (SetAuto)
		autoSource = { Tag = "", Mode = "Foam", Falloff = 3.5, Strength = 0.8 } :: Source,
		records = {} :: { Record },
		count = 0,
		results = {} :: { Record },
		connections = {} :: { RBXScriptConnection },
	}, Masks)

	for _, source in sources do
		for _, instance in CollectionService:GetTagged(source.Tag) do
			self:_add(instance, source)
		end
		table.insert(
			self.connections,
			CollectionService:GetInstanceAddedSignal(source.Tag):Connect(function(instance)
				self:_add(instance, source)
			end)
		)
		table.insert(
			self.connections,
			CollectionService:GetInstanceRemovedSignal(source.Tag):Connect(function(instance)
				self.instances[instance] = nil
			end)
		)
	end
	return self
end

function Masks:_add(instance: Instance, source: Source)
	if instance:IsA("BasePart") or instance:IsA("Model") then
		self.instances[instance] = source
	end
end

--[[
	The parts that foam where they cross the water, chosen by the Contact scan (not by a tag): each
	becomes a Foam mask with this soft edge (studs) and strength, so the foam is part of the water
	surface and joins the part it touches.
]]
function Masks:SetAuto(parts: { Instance }, falloff: number, strength: number)
	table.clear(self.autoParts)
	for _, part in parts do
		self.autoParts[part] = true
	end
	self.autoSource.Falloff, self.autoSource.Strength = falloff, strength
end

function Masks:Destroy()
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
	table.clear(self.instances)
	self.count = 0
end

-- Refreshes every mask's placement. Call once per frame before sampling.
function Masks:Update()
	local records = self.records
	local count = 0

	local function place(instance: Instance, source: Source)
		if not instance:IsDescendantOf(workspace) then
			return
		end

		local cf, size
		local part: BasePart? = nil
		if instance:IsA("Model") then
			cf, size = instance:GetBoundingBox()
		else
			part = instance :: BasePart
			cf, size = (part :: BasePart).CFrame, (part :: BasePart).Size
		end

		local mode = MODES[instance:GetAttribute("Mode") :: any] or MODES[source.Mode] or MODE_CALM
		local shape = instance:GetAttribute("Shape")
		local ellipse
		if shape == "Ellipse" then
			ellipse = true
		elseif shape == "Box" then
			ellipse = false
		else
			ellipse = part ~= nil
				and part:IsA("Part")
				and (part.Shape == Enum.PartType.Ball or part.Shape == Enum.PartType.Cylinder)
		end

		local falloff = instance:GetAttribute("Falloff")
		if type(falloff) ~= "number" then
			falloff = instance:GetAttribute("OceanShore")
		end
		if type(falloff) ~= "number" then
			falloff = source.Falloff
		end
		if mode == MODE_CUTOUT then
			falloff = 0
		end
		local strength = instance:GetAttribute("Strength")
		if type(strength) ~= "number" then
			strength = instance:GetAttribute("OceanCalmness")
		end
		if type(strength) ~= "number" then
			strength = source.Strength or 1
		end

		local axes = { cf.RightVector, cf.UpVector, -cf.LookVector }
		local halves = { size.X / 2, size.Y / 2, size.Z / 2 }

		-- The most vertical local axis is the part's height; the other two span the footprint
		local vertical = 1
		for i = 2, 3 do
			if math.abs(axes[i].Y) > math.abs(axes[vertical].Y) then
				vertical = i
			end
		end
		local first = if vertical == 1 then 2 else 1
		local second = if vertical == 3 then 2 else 3
		local a, b = axes[first], axes[second]

		count += 1
		local record = records[count]
		if not record then
			record = {} :: any
			records[count] = record
		end
		record.mode = mode
		record.ellipse = ellipse
		record.falloff = math.max(falloff, 0)
		record.strength = math.clamp(strength, 0, 1)
		record.cx, record.cy, record.cz = cf.X, cf.Y, cf.Z
		record.ax, record.ay, record.az = a.X, a.Y, a.Z
		record.bx, record.by, record.bz = b.X, b.Y, b.Z
		record.ha, record.hb = math.max(halves[first], 0.01), math.max(halves[second], 0.01)

		local r, u, k = axes[1], axes[2], axes[3]
		record.bottom = cf.Y - (math.abs(r.Y) * size.X + math.abs(u.Y) * size.Y + math.abs(k.Y) * size.Z) / 2
		local extentX = (math.abs(r.X) * size.X + math.abs(u.X) * size.Y + math.abs(k.X) * size.Z) / 2 + record.falloff
		local extentZ = (math.abs(r.Z) * size.X + math.abs(u.Z) * size.Y + math.abs(k.Z) * size.Z) / 2 + record.falloff
		record.minX, record.maxX = cf.X - extentX, cf.X + extentX
		record.minZ, record.maxZ = cf.Z - extentZ, cf.Z + extentZ
	end

	for instance, source in self.instances do
		place(instance, source)
	end
	for instance in self.autoParts do
		place(instance, self.autoSource)
	end

	self.count = count
end

-- Masks whose area overlaps the rectangle. The returned table is reused by
-- the next call, so read it right away.
function Masks:Query(minX: number, minZ: number, maxX: number, maxZ: number): ({ Record }, number)
	local results = self.results
	local found = 0
	local records = self.records
	for i = 1, self.count do
		local record = records[i]
		if record.maxX >= minX and record.minX <= maxX and record.maxZ >= minZ and record.minZ <= maxZ then
			found += 1
			results[found] = record
		end
	end
	return results, found
end

--[[
	Evaluates masks at a point on the water plane (x, y = sea level, z).
	Returns the wave amplitude multiplier (0..1), extra foam, and the height
	the water must stay below (math.huge when no cutout applies).
]]
function Masks.evaluate(list: { Record }, count: number, x: number, y: number, z: number): (number, number, number)
	local amplitude, foam, cut = 1, 0, math.huge
	for i = 1, count do
		local record = list[i]
		local px, py, pz = x - record.cx, y - record.cy, z - record.cz
		local la = px * record.ax + py * record.ay + pz * record.az
		local lb = px * record.bx + py * record.by + pz * record.bz

		local ha, hb = record.ha, record.hb
		local distance
		if record.ellipse then
			local ea, eb = la / ha, lb / hb
			distance = (math.sqrt(ea * ea + eb * eb) - 1) * math.min(ha, hb)
		else
			local qa, qb = math.abs(la) - ha, math.abs(lb) - hb
			local oa, ob = math.max(qa, 0), math.max(qb, 0)
			distance = math.sqrt(oa * oa + ob * ob) + math.min(math.max(qa, qb), 0)
		end

		local mode = record.mode
		if mode == MODE_CUTOUT then
			if distance <= 0 then
				local limit = record.bottom - 0.25
				if limit < cut then
					cut = limit
				end
			end
			continue
		end

		local influence
		if distance <= 0 then
			influence = 1
		elseif distance >= record.falloff then
			influence = 0
		else
			local t = 1 - distance / record.falloff
			influence = t * t * (3 - 2 * t)
		end

		if influence > 0 then
			local s = influence * record.strength
			if mode == MODE_CALM then
				amplitude *= 1 - s
			else
				foam += s
			end
		end
	end
	return amplitude, foam, cut
end

-- Wave amplitude multiplier at a point, for height queries
function Masks:AmplitudeAt(x: number, y: number, z: number): number
	if self.count == 0 then
		return 1
	end
	local list, count = self:Query(x, z, x, z)
	if count == 0 then
		return 1
	end
	return (Masks.evaluate(list, count, x, y, z))
end

return Masks

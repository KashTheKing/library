--!strict
--[=[
	@class Snapshot
	Serializes the visible state of a part or model into a compact buffer and
	rebuilds it as an anchored proxy. Every BasePart descendant is kept with
	its offset from the root, size, appearance, surfaces, decals and textures,
	meshes, PBR surface appearance, attachments and the effects on them
	(sounds, particle emitters, beams, trails, fire, smoke, sparkles, lights). Models with a Humanoid also keep
	clothing and body colours so rigs and NPCs look right on playback.

	MeshPart meshes come back as real MeshParts built through
	`AssetService:CreateMeshPartAsync` (call `prefetch` first; it yields), so
	clothing, body colours and surface appearance render exactly as recorded.
	Without a prefetched mesh a Part carrying a scaled SpecialMesh stands in.
	Joints (Motor6D, Weld, AnimationConstraint and RigidConstraint) are kept
	so rebuilt rigs still animate. Constraint joints come back as Motor6D and
	Weld built from their attachment offsets: the Animator drives those
	kinematically, so playback also works in Studio edit mode where physics
	(and therefore AnimationConstraint) does not run.

	UnionOperation geometry cannot be read back at runtime. Unions are stored
	by key (their full name when recorded) and resolved through `links` or the
	same path on playback; unresolved unions fall back to a plain Part.

	Every snapshot also carries the source key of the instance it was taken
	from. Linking that key to a prefab (for example under ReplicatedStorage)
	makes playback clone the prefab instead of rebuilding from the snapshot,
	which is the way to bring back models whose geometry cannot be serialized.
]=]

local AssetService = game:GetService("AssetService")

local Serializer = require(script.Parent.Serializer)

local Snapshot = {}

local VERSION = 10

local KIND_PART = 0
local KIND_MESH = 1
local KIND_WEDGE = 2
local KIND_CORNER_WEDGE = 3
local KIND_OTHER = 4
local KIND_UNION = 5

local SURFACE_PROPS = { "TopSurface", "BottomSurface", "LeftSurface", "RightSurface", "FrontSurface", "BackSurface" }

local function kindOf(part: BasePart): number
	if part:IsA("UnionOperation") then
		return KIND_UNION
	elseif part:IsA("MeshPart") then
		return KIND_MESH
	elseif part:IsA("WedgePart") then
		return KIND_WEDGE
	elseif part:IsA("CornerWedgePart") then
		return KIND_CORNER_WEDGE
	elseif part:IsA("Part") then
		return KIND_PART
	end
	return KIND_OTHER
end

--[=[
	The part whose CFrame stands for an instance: the part itself, a model's
	PrimaryPart, or its first part. Shared with the Recorder so recorded
	transforms and snapshot offsets always refer to the same part.
	@within Snapshot
]=]
function Snapshot.rootOf(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	end
	local primary = if inst:IsA("Model") then inst.PrimaryPart else nil
	return primary or inst:FindFirstChildWhichIsA("BasePart") or inst:FindFirstChildWhichIsA("BasePart", true)
end

local rootOf = Snapshot.rootOf

--[=[
	Path segment for an instance: its name, followed by `#n` when other
	siblings share that name (n counts same-named siblings in child order).
	Names alone are ambiguous inside many models (several `Wheel`s, several
	unions called `Union`), and runtime scripts cannot read `UniqueId`.
	@within Snapshot
]=]
function Snapshot.segment(inst: Instance): string
	local parent = inst.Parent
	if not parent then
		return inst.Name
	end
	local index, total = 0, 0
	for _, sibling in parent:GetChildren() do
		if sibling.Name == inst.Name then
			total += 1
			if sibling == inst then
				index = total
			end
		end
	end
	return if total > 1 then `{inst.Name}#{index}` else inst.Name
end

--[=[
	Resolves one segment under `parent`: an exact name first (names may
	contain `#`), then the `Name#n` form.
	@within Snapshot
]=]
function Snapshot.child(parent: Instance, segment: string): Instance?
	local exact = parent:FindFirstChild(segment)
	if exact then
		return exact
	end
	local name, n = segment:match("^(.*)#(%d+)$")
	if not name then
		return nil
	end
	local wanted = tonumber(n) :: number
	local seen = 0
	for _, sibling in parent:GetChildren() do
		if sibling.Name == name then
			seen += 1
			if seen == wanted then
				return sibling
			end
		end
	end
	return nil
end

--[=[
	Segments of `inst` below `root`, joined with `/`. Nil when `inst` is not
	inside `root`; empty when they are the same instance.
	@within Snapshot
]=]
function Snapshot.pathWithin(inst: Instance, root: Instance): string?
	local names = {}
	local current: Instance? = inst
	while current and current ~= root do
		table.insert(names, 1, Snapshot.segment(current))
		current = current.Parent
	end
	if current ~= root then
		return nil
	end
	return table.concat(names, "/")
end

--[=[
	Follows a `/` path from `root`.
	@within Snapshot
]=]
function Snapshot.resolve(root: Instance, path: string): Instance?
	local current: Instance? = root
	if path ~= "" then
		for _, segment in path:split("/") do
			current = if current then Snapshot.child(current, segment) else nil
		end
	end
	return current
end

--[=[
	Unique full path from the DataModel, dotted like `GetFullName` but with
	`#n` on ambiguous segments.
	@within Snapshot
]=]
function Snapshot.pathOf(inst: Instance): string
	local dotted = (Snapshot.pathWithin(inst, game) or inst:GetFullName()):gsub("/", ".")
	return dotted
end

local function containerAt(inst: Instance, path: string): Instance
	local current = inst
	if path ~= "" then
		for _, segment in path:split("/") do
			local nxt = Snapshot.child(current, segment)
			if not nxt then
				local name = segment:match("^(.*)#%d+$") or segment
				repeat
					local folder = Instance.new("Folder")
					folder.Name = name
					folder.Parent = current
					nxt = Snapshot.child(current, segment)
				until nxt
			end
			current = nxt :: Instance
		end
	end
	return current
end

local function enumByValue(enum: Enum, value: number): EnumItem?
	for _, item in enum:GetEnumItems() do
		if item.Value == value then
			return item
		end
	end
	return nil
end

local function writeColor(w: Serializer.Writer, c: Color3)
	w:u8(math.round(c.R * 255))
	w:u8(math.round(c.G * 255))
	w:u8(math.round(c.B * 255))
end

local function readColor(r: Serializer.Reader): Color3
	return Color3.fromRGB(r:u8(), r:u8(), r:u8())
end

local function unit(v: number): number
	return math.round(math.clamp(v, 0, 1) * 255)
end

local function writeVector(w: Serializer.Writer, v: Vector3)
	w:f32(v.X)
	w:f32(v.Y)
	w:f32(v.Z)
end

local function readVector(r: Serializer.Reader): Vector3
	return Vector3.new(r:f32(), r:f32(), r:f32())
end

local function writeDecals(w: Serializer.Writer, part: BasePart)
	local decals = {}
	for _, child in part:GetChildren() do
		if child:IsA("Decal") then
			table.insert(decals, child)
		end
	end
	w:u8(math.min(#decals, 255))
	for i = 1, math.min(#decals, 255) do
		local decal = decals[i]
		w:u8(if decal:IsA("Texture") then 1 else 0)
		w:u8(decal.Face.Value)
		w:str16(decal.Texture)
		w:u8(unit(decal.Transparency))
		writeColor(w, decal.Color3)
		w:u8(decal.ZIndex % 256)
		if decal:IsA("Texture") then
			w:f32(decal.StudsPerTileU)
			w:f32(decal.StudsPerTileV)
			w:f32(decal.OffsetStudsU)
			w:f32(decal.OffsetStudsV)
		end
	end
end

local function readDecals(r: Serializer.Reader, part: BasePart)
	local count = r:u8()
	for _ = 1, count do
		local isTexture = r:u8() == 1
		local face = enumByValue(Enum.NormalId, r:u8())
		local texture = r:str16()
		local transparency = r:u8() / 255
		local color = readColor(r)
		local zIndex = r:u8()
		local decal: Decal = if isTexture then Instance.new("Texture") else Instance.new("Decal")
		if face then
			decal.Face = face :: Enum.NormalId
		end
		decal.Texture = texture
		decal.Transparency = transparency
		decal.Color3 = color
		decal.ZIndex = zIndex
		if isTexture and decal:IsA("Texture") then
			decal.StudsPerTileU = r:f32()
			decal.StudsPerTileV = r:f32()
			decal.OffsetStudsU = r:f32()
			decal.OffsetStudsV = r:f32()
		end
		decal.Parent = part
	end
end

local function writeSpecialMesh(w: Serializer.Writer, part: BasePart)
	local mesh = part:FindFirstChildWhichIsA("SpecialMesh")
	if not mesh then
		w:u8(0)
		return
	end
	w:u8(1)
	w:u8(mesh.MeshType.Value)
	w:str16(mesh.MeshId)
	w:str16(mesh.TextureId)
	writeVector(w, mesh.Scale)
	writeVector(w, mesh.Offset)
	writeVector(w, mesh.VertexColor)
end

local function readSpecialMesh(r: Serializer.Reader, part: BasePart)
	if r:u8() == 0 then
		return
	end
	local mesh = Instance.new("SpecialMesh")
	local meshType = enumByValue(Enum.MeshType, r:u8())
	if meshType then
		mesh.MeshType = meshType :: Enum.MeshType
	end
	mesh.MeshId = r:str16()
	mesh.TextureId = r:str16()
	mesh.Scale = readVector(r)
	mesh.Offset = readVector(r)
	mesh.VertexColor = readVector(r)
	mesh.Parent = part
end

local function writeSurfaceAppearance(w: Serializer.Writer, part: BasePart)
	local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
	if not appearance then
		w:u8(0)
		return
	end
	w:u8(1)
	w:str16(appearance.ColorMap)
	w:str16(appearance.NormalMap)
	w:str16(appearance.MetalnessMap)
	w:str16(appearance.RoughnessMap)
	w:u8(appearance.AlphaMode.Value)
	writeColor(w, appearance.Color)
end

local function readSurfaceAppearance(r: Serializer.Reader, part: BasePart)
	if r:u8() == 0 then
		return
	end
	local colorMap, normalMap, metalnessMap, roughnessMap = r:str16(), r:str16(), r:str16(), r:str16()
	local alphaMode = enumByValue(Enum.AlphaMode, r:u8())
	local color = readColor(r)
	pcall(function()
		local appearance = Instance.new("SurfaceAppearance")
		appearance.ColorMap = colorMap
		appearance.NormalMap = normalMap
		appearance.MetalnessMap = metalnessMap
		appearance.RoughnessMap = roughnessMap
		if alphaMode then
			appearance.AlphaMode = alphaMode :: Enum.AlphaMode
		end
		appearance.Color = color
		appearance.Parent = part
	end)
end

local JOINT_WELD, JOINT_MOTOR, JOINT_ANIMATION, JOINT_RIGID = 1, 2, 3, 4

local function attachmentPart(att: Instance?): BasePart?
	local parent = if att then att.Parent else nil
	return if parent and parent:IsA("BasePart") then parent else nil
end

-- Every Motor6D, Weld, AnimationConstraint and RigidConstraint whose two
-- parts are both in the snapshot, written once per model with part indices
-- so accessory joints never displace a limb's own joint. Constraints refer
-- to attachments by part index and attachment name, since rig attachment
-- names repeat across parts.
local function writeJoints(w: Serializer.Writer, scope: Instance, index: { [Instance]: number })
	local joints: { Instance } = {}
	for _, d in scope:GetDescendants() do
		if (d:IsA("Motor6D") or d:IsA("Weld")) and d.Part0 and d.Part1 and index[d.Part0] and index[d.Part1] then
			table.insert(joints, d)
		elseif d:IsA("AnimationConstraint") or d:IsA("RigidConstraint") then
			local p0, p1 = attachmentPart(d.Attachment0), attachmentPart(d.Attachment1)
			if p0 and p1 and index[p0] and index[p1] then
				table.insert(joints, d)
			end
		end
	end
	w:u16(#joints)
	for _, joint in joints do
		if joint:IsA("JointInstance") then
			w:u8(if joint:IsA("Motor6D") then JOINT_MOTOR else JOINT_WELD)
			w:str16(joint.Name)
			local part0: Instance, part1: Instance = (joint :: any).Part0, (joint :: any).Part1
			w:u16(index[joint.Parent :: Instance] or index[part1])
			w:u16(index[part0])
			w:u16(index[part1])
			writeVector(w, joint.C0.Position)
			Serializer.writeRotation(w, joint.C0)
			writeVector(w, joint.C1.Position)
			Serializer.writeRotation(w, joint.C1)
		else
			local c = joint :: any
			local a0: Instance, a1: Instance = c.Attachment0, c.Attachment1
			w:u8(if joint:IsA("AnimationConstraint") then JOINT_ANIMATION else JOINT_RIGID)
			w:str16(joint.Name)
			w:u16(index[joint.Parent :: Instance] or index[a1.Parent :: Instance])
			w:u16(index[a0.Parent :: Instance])
			w:str16(a0.Name)
			w:u16(index[a1.Parent :: Instance])
			w:str16(a1.Name)
		end
	end
end

local function readJoints(r: Serializer.Reader, parts: { BasePart })
	for _ = 1, r:u16() do
		local kind = r:u8()
		local name = r:str16()
		local holder = parts[r:u16()]
		if kind == JOINT_MOTOR or kind == JOINT_WELD then
			local part0, part1 = parts[r:u16()], parts[r:u16()]
			local c0 = CFrame.new(readVector(r)) * Serializer.readRotation(r)
			local c1 = CFrame.new(readVector(r)) * Serializer.readRotation(r)
			if part0 and part1 then
				local joint: JointInstance = if kind == JOINT_MOTOR
					then Instance.new("Motor6D")
					else Instance.new("Weld")
				joint.Name = name
				joint.Part0 = part0
				joint.Part1 = part1
				joint.C0 = c0
				joint.C1 = c1
				joint.Parent = holder or part1
			end
		else
			local part0 = parts[r:u16()]
			local att0Name = r:str16()
			local part1 = parts[r:u16()]
			local att1Name = r:str16()
			local a0 = if part0 then part0:FindFirstChild(att0Name) else nil
			local a1 = if part1 then part1:FindFirstChild(att1Name) else nil
			if a0 and a0:IsA("Attachment") and a1 and a1:IsA("Attachment") then
				local joint: JointInstance = if kind == JOINT_ANIMATION
					then Instance.new("Motor6D")
					else Instance.new("Weld")
				joint.Name = name
				joint.Part0 = part0
				joint.Part1 = part1
				joint.C0 = a0.CFrame
				joint.C1 = a1.CFrame
				joint.Parent = holder or part1
			end
		end
	end
end

--[=[
	Walks a dotted path (see `pathOf`) from the DataModel. Returns nil when
	any segment is missing.
	@within Snapshot
]=]
function Snapshot.instanceAt(key: string): Instance?
	local current: Instance? = game
	for segment in key:gmatch("[^%.]+") do
		current = if current then Snapshot.child(current, segment) else nil
	end
	return if current ~= game then current else nil
end

-- Manual links set by the plugin: a union key -> UnionOperation, or a
-- snapshot source key -> prefab to clone in place of the rebuilt geometry.
Snapshot.links = {} :: { [string]: Instance? }

function Snapshot.link(key: string, inst: Instance?)
	Snapshot.links[key] = inst
end

export type Keys = { source: string, root: string, isModel: boolean, unions: { string }, meshes: { string } }

local meshTemplates: { [string]: MeshPart | false } = {}

--[=[
	Creates a MeshPart template for every mesh id a snapshot uses. Yields on
	first use of each id; later builds are synchronous. Ids that fail to load
	fall back to a SpecialMesh at build time.
	@within Snapshot
]=]
function Snapshot.prefetch(data: buffer)
	for _, meshId in Snapshot.keys(data).meshes do
		if meshTemplates[meshId] == nil then
			local ok, part = pcall(function()
				return AssetService:CreateMeshPartAsync(Content.fromUri(meshId), {
					CollisionFidelity = Enum.CollisionFidelity.Box,
					RenderFidelity = Enum.RenderFidelity.Automatic,
				})
			end)
			meshTemplates[meshId] = if ok and part then part else false
		end
	end
end

--[=[
	Finds the UnionOperation a key refers to: a manual link first, then the
	instance at the same path the union had when recorded.
	@within Snapshot
]=]
function Snapshot.resolveUnion(key: string): UnionOperation?
	local inst = Snapshot.links[key] or Snapshot.instanceAt(key)
	return if inst and inst:IsA("UnionOperation") then inst else nil
end

--[=[
	Reads the source key and the union keys a snapshot depends on without
	rebuilding it.
	@within Snapshot
]=]
function Snapshot.keys(data: buffer): Keys
	local r = Serializer.newReader(data)
	local version = r:u8()
	assert(version == VERSION, `unsupported snapshot version {version}`)
	local isModel = r:u8() == 1
	r:str16()
	local source = r:str16()
	local root = r:str16()
	local unions = {}
	for i = 1, r:u16() do
		unions[i] = r:str16()
	end
	local meshes = {}
	for i = 1, r:u16() do
		meshes[i] = r:str16()
	end
	return { source = source, root = root, isModel = isModel, unions = unions, meshes = meshes }
end

local EFFECT_PROPS: { [string]: { string } } = {
	Attachment = { "Position", "Orientation" },
	Sound = {
		"SoundId",
		"Volume",
		"PlaybackSpeed",
		"Looped",
		"Playing",
		"TimePosition",
		"RollOffMinDistance",
		"RollOffMaxDistance",
		"RollOffMode",
	},
	ParticleEmitter = {
		"Texture",
		"Enabled",
		"Rate",
		"Lifetime",
		"Speed",
		"Size",
		"Transparency",
		"Color",
		"Squash",
		"LightEmission",
		"LightInfluence",
		"Rotation",
		"RotSpeed",
		"SpreadAngle",
		"Acceleration",
		"Drag",
		"EmissionDirection",
		"Orientation",
		"Shape",
		"ShapeStyle",
		"ShapeInOut",
		"ShapePartial",
		"ZOffset",
		"Brightness",
		"LockedToPart",
		"VelocityInheritance",
		"TimeScale",
		"FlipbookLayout",
		"FlipbookMode",
		"FlipbookFramerate",
		"FlipbookStartRandom",
	},
	Beam = {
		"Attachment0",
		"Attachment1",
		"Texture",
		"TextureLength",
		"TextureMode",
		"TextureSpeed",
		"Color",
		"Transparency",
		"Width0",
		"Width1",
		"CurveSize0",
		"CurveSize1",
		"Segments",
		"LightEmission",
		"LightInfluence",
		"FaceCamera",
		"ZOffset",
		"Enabled",
		"Brightness",
	},
	Trail = {
		"Attachment0",
		"Attachment1",
		"Texture",
		"TextureLength",
		"TextureMode",
		"Color",
		"Transparency",
		"Lifetime",
		"MinLength",
		"MaxLength",
		"WidthScale",
		"LightEmission",
		"LightInfluence",
		"FaceCamera",
		"Enabled",
		"Brightness",
	},
	Fire = { "Enabled", "Size", "Heat", "Color", "SecondaryColor", "TimeScale" },
	Smoke = { "Enabled", "Size", "Opacity", "RiseVelocity", "Color", "TimeScale" },
	Sparkles = { "Enabled", "SparkleColor", "TimeScale" },
	PointLight = { "Enabled", "Brightness", "Color", "Range", "Shadows" },
	SpotLight = { "Enabled", "Brightness", "Color", "Range", "Shadows", "Angle", "Face" },
	SurfaceLight = { "Enabled", "Brightness", "Color", "Range", "Shadows", "Angle", "Face" },
}

local EFFECT_CLASSES = {
	"Attachment",
	"Sound",
	"ParticleEmitter",
	"Beam",
	"Trail",
	"Fire",
	"Smoke",
	"Sparkles",
	"PointLight",
	"SpotLight",
	"SurfaceLight",
}
local EFFECT_INDEX: { [string]: number } = {}
for i, name in EFFECT_CLASSES do
	EFFECT_INDEX[name] = i
end

local VT_BOOL, VT_NUMBER, VT_STRING, VT_COLOR, VT_VECTOR3, VT_VECTOR2, VT_RANGE, VT_NSEQ, VT_CSEQ, VT_ENUM, VT_REF =
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10

local function writeValue(w: Serializer.Writer, v: any): boolean
	local t = typeof(v)
	if t == "boolean" then
		w:u8(VT_BOOL)
		w:u8(if v then 1 else 0)
	elseif t == "number" then
		w:u8(VT_NUMBER)
		w:f32(v)
	elseif t == "string" then
		w:u8(VT_STRING)
		w:str16(v)
	elseif t == "Color3" then
		w:u8(VT_COLOR)
		writeColor(w, v)
	elseif t == "Vector3" then
		w:u8(VT_VECTOR3)
		writeVector(w, v)
	elseif t == "Vector2" then
		w:u8(VT_VECTOR2)
		w:f32(v.X)
		w:f32(v.Y)
	elseif t == "NumberRange" then
		w:u8(VT_RANGE)
		w:f32(v.Min)
		w:f32(v.Max)
	elseif t == "NumberSequence" then
		w:u8(VT_NSEQ)
		local keys = v.Keypoints
		w:u8(math.min(#keys, 255))
		for i = 1, math.min(#keys, 255) do
			w:f32(keys[i].Time)
			w:f32(keys[i].Value)
			w:f32(keys[i].Envelope)
		end
	elseif t == "ColorSequence" then
		w:u8(VT_CSEQ)
		local keys = v.Keypoints
		w:u8(math.min(#keys, 255))
		for i = 1, math.min(#keys, 255) do
			w:f32(keys[i].Time)
			writeColor(w, keys[i].Value)
		end
	elseif t == "EnumItem" then
		w:u8(VT_ENUM)
		w:str16(v.Name)
	elseif t == "Instance" and v:IsA("Attachment") then
		w:u8(VT_REF)
		w:str16(v.Name)
	else
		return false
	end
	return true
end

local function readValue(r: Serializer.Reader): (number, any)
	local tag = r:u8()
	if tag == VT_BOOL then
		return tag, r:u8() == 1
	elseif tag == VT_NUMBER then
		return tag, r:f32()
	elseif tag == VT_STRING or tag == VT_ENUM or tag == VT_REF then
		return tag, r:str16()
	elseif tag == VT_COLOR then
		return tag, readColor(r)
	elseif tag == VT_VECTOR3 then
		return tag, readVector(r)
	elseif tag == VT_VECTOR2 then
		return tag, Vector2.new(r:f32(), r:f32())
	elseif tag == VT_RANGE then
		local lo, hi = r:f32(), r:f32()
		return tag, NumberRange.new(lo, math.max(lo, hi))
	elseif tag == VT_NSEQ then
		local keys = {}
		for i = 1, r:u8() do
			local time, value, envelope = r:f32(), r:f32(), r:f32()
			keys[i] = NumberSequenceKeypoint.new(time, value, envelope)
		end
		return tag, NumberSequence.new(keys)
	elseif tag == VT_CSEQ then
		local keys = {}
		for i = 1, r:u8() do
			local time = r:f32()
			keys[i] = ColorSequenceKeypoint.new(time, readColor(r))
		end
		return tag, ColorSequence.new(keys)
	end
	error(`unknown effect value tag {tag}`)
end

-- Effects are Attachments and the emitters, lights and sounds that live on a
-- part or on one of its attachments. Attachments come first so later entries
-- can reference them by index as their parent.
local function writeEffects(w: Serializer.Writer, part: BasePart)
	local list: { Instance } = {}
	local parentIndex: { [Instance]: number } = {}
	for _, child in part:GetChildren() do
		if child:IsA("Attachment") then
			table.insert(list, child)
			parentIndex[child] = 0
		end
	end
	local attachmentCount = #list
	for _, child in part:GetChildren() do
		if EFFECT_INDEX[child.ClassName] and not child:IsA("Attachment") then
			table.insert(list, child)
			parentIndex[child] = 0
		end
	end
	for i = 1, attachmentCount do
		for _, child in list[i]:GetChildren() do
			if EFFECT_INDEX[child.ClassName] and not child:IsA("Attachment") then
				table.insert(list, child)
				parentIndex[child] = i
			end
		end
	end
	w:u8(math.min(#list, 255))
	for i = 1, math.min(#list, 255) do
		local effect = list[i]
		w:u8(EFFECT_INDEX[effect.ClassName])
		w:u8(parentIndex[effect])
		w:str16(effect.Name)
		local props = EFFECT_PROPS[effect.ClassName]
		local countPos = w.pos
		w:u8(0)
		local written = 0
		for propIndex, name in props do
			local ok, v = pcall(function()
				return (effect :: any)[name]
			end)
			if ok and v ~= nil then
				local before = w.pos
				w:u8(propIndex)
				if writeValue(w, v) then
					written += 1
				else
					w.pos = before
				end
			end
		end
		local endPos = w.pos
		w.pos = countPos
		w:u8(written)
		w.pos = endPos
	end
end

type PendingRef = { inst: Instance, name: string, target: string }

local function readEffects(r: Serializer.Reader, part: BasePart, refs: { PendingRef })
	local built: { Instance } = {}
	for i = 1, r:u8() do
		local className = EFFECT_CLASSES[r:u8()]
		local parent = r:u8()
		local name = r:str16()
		local inst = Instance.new(className)
		inst.Name = name
		for _ = 1, r:u8() do
			local prop = EFFECT_PROPS[className][r:u8()]
			local tag, value = readValue(r)
			if tag == VT_REF then
				table.insert(refs, { inst = inst, name = prop, target = value })
			elseif tag == VT_ENUM then
				pcall(function()
					local target = inst :: any
					local enumType: any = target[prop].EnumType
					target[prop] = enumType[value]
				end)
			else
				pcall(function()
					(inst :: any)[prop] = value
				end)
			end
		end
		built[i] = inst
		inst.Parent = if parent == 0 then part else built[parent]
	end
end

local function writeRig(w: Serializer.Writer, inst: Instance)
	local humanoid = inst:FindFirstChildWhichIsA("Humanoid")
	if not humanoid then
		w:u8(0)
		return
	end
	w:u8(1)
	w:u8(humanoid.RigType.Value)
	local shirt = inst:FindFirstChildWhichIsA("Shirt")
	local pants = inst:FindFirstChildWhichIsA("Pants")
	local graphic = inst:FindFirstChildWhichIsA("ShirtGraphic")
	w:str16(if shirt then shirt.ShirtTemplate else "")
	w:str16(if pants then pants.PantsTemplate else "")
	w:str16(if graphic then graphic.Graphic else "")
	local colors = inst:FindFirstChildWhichIsA("BodyColors")
	w:u8(if colors then 1 else 0)
	if colors then
		writeColor(w, colors.HeadColor3)
		writeColor(w, colors.TorsoColor3)
		writeColor(w, colors.LeftArmColor3)
		writeColor(w, colors.RightArmColor3)
		writeColor(w, colors.LeftLegColor3)
		writeColor(w, colors.RightLegColor3)
	end
	local meshes = {}
	for _, child in inst:GetChildren() do
		if child:IsA("CharacterMesh") then
			table.insert(meshes, child)
		end
	end
	w:u8(math.min(#meshes, 255))
	for i = 1, math.min(#meshes, 255) do
		local mesh = meshes[i]
		w:u8(mesh.BodyPart.Value)
		w:f64(mesh.MeshId)
		w:f64(mesh.BaseTextureId)
		w:f64(mesh.OverlayTextureId)
	end
end

local function readRig(r: Serializer.Reader, model: Model)
	if r:u8() == 0 then
		return
	end
	local humanoid = Instance.new("Humanoid")
	local rigType = enumByValue(Enum.HumanoidRigType, r:u8())
	if rigType then
		humanoid.RigType = rigType :: Enum.HumanoidRigType
	end
	humanoid.EvaluateStateMachine = false
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model
	local shirtTemplate, pantsTemplate, graphicTemplate = r:str16(), r:str16(), r:str16()
	if shirtTemplate ~= "" then
		local shirt = Instance.new("Shirt")
		shirt.ShirtTemplate = shirtTemplate
		shirt.Parent = model
	end
	if pantsTemplate ~= "" then
		local pants = Instance.new("Pants")
		pants.PantsTemplate = pantsTemplate
		pants.Parent = model
	end
	if graphicTemplate ~= "" then
		local graphic = Instance.new("ShirtGraphic")
		graphic.Graphic = graphicTemplate
		graphic.Parent = model
	end
	if r:u8() == 1 then
		local colors = Instance.new("BodyColors")
		colors.HeadColor3 = readColor(r)
		colors.TorsoColor3 = readColor(r)
		colors.LeftArmColor3 = readColor(r)
		colors.RightArmColor3 = readColor(r)
		colors.LeftLegColor3 = readColor(r)
		colors.RightLegColor3 = readColor(r)
		colors.Parent = model
	end
	for _ = 1, r:u8() do
		local mesh = Instance.new("CharacterMesh")
		local bodyPart = enumByValue(Enum.BodyPart, r:u8())
		if bodyPart then
			mesh.BodyPart = bodyPart :: Enum.BodyPart
		end
		mesh.MeshId = r:f64()
		mesh.BaseTextureId = r:f64()
		mesh.OverlayTextureId = r:f64()
		mesh.Parent = model
	end
end

--[=[
	Captures `inst` relative to its root part. Returns nil when there is no
	geometry to capture. Descendants for which `exclude` returns true are
	left out along with everything inside them.
	@within Snapshot
]=]
function Snapshot.capture(inst: Instance, exclude: ((Instance) -> boolean)?): buffer?
	local root = rootOf(inst)
	if not root then
		return nil
	end
	local parts: { BasePart } = { root }
	local excluded: { Instance } = {}
	for _, d in inst:GetDescendants() do
		if exclude and exclude(d) then
			table.insert(excluded, d)
			continue
		end
		local inside = false
		for _, ex in excluded do
			if d:IsDescendantOf(ex) then
				inside = true
				break
			end
		end
		if d:IsA("BasePart") and d ~= root and not inside then
			table.insert(parts, d)
		end
	end
	if #parts == 0 then
		return nil
	end
	local rootCF = root.CFrame
	local w = Serializer.newWriter(96 * #parts)
	w:u8(VERSION)
	w:u8(if inst:IsA("Model") then 1 else 0)
	w:str16(inst.Name)
	w:str16(Snapshot.pathOf(inst))
	w:str16(Snapshot.pathWithin(root, inst) or "")
	local unionKeys: { string } = {}
	local unionIndex: { [BasePart]: number } = {}
	for _, part in parts do
		if part:IsA("UnionOperation") then
			table.insert(unionKeys, Snapshot.pathOf(part))
			unionIndex[part] = #unionKeys
		end
	end
	w:u16(#unionKeys)
	for _, key in unionKeys do
		w:str16(key)
	end
	local meshIds: { string } = {}
	for _, part in parts do
		if part:IsA("MeshPart") and part.MeshId ~= "" and not table.find(meshIds, part.MeshId) then
			table.insert(meshIds, part.MeshId)
		end
	end
	w:u16(#meshIds)
	for _, meshId in meshIds do
		w:str16(meshId)
	end
	if inst:IsA("Model") then
		writeRig(w, inst)
	end
	w:u16(#parts)
	for _, part in parts do
		local rel = rootCF:ToObjectSpace(part.CFrame)
		w:u8(kindOf(part))
		if unionIndex[part] then
			w:u16(unionIndex[part])
		end
		w:str16(part.Name)
		w:str16(Snapshot.pathWithin(part.Parent :: Instance, inst) or "")
		writeVector(w, rel.Position)
		Serializer.writeRotation(w, rel)
		writeVector(w, part.Size)
		writeColor(w, part.Color)
		w:u16(part.Material.Value)
		w:u8(unit(part.Transparency))
		w:u8(unit(part.Reflectance))
		w:u8(if part:IsA("Part") then part.Shape.Value else 0)
		for _, prop in SURFACE_PROPS do
			w:u8(((part :: any)[prop] :: Enum.SurfaceType).Value)
		end
		if part:IsA("MeshPart") then
			w:str16(part.MeshId)
			w:str16(part.TextureID)
			writeVector(w, part.MeshSize)
		end
		writeSpecialMesh(w, part)
		writeSurfaceAppearance(w, part)
		writeDecals(w, part)
		writeEffects(w, part)
	end
	local index: { [Instance]: number } = {}
	for i, part in parts do
		index[part] = i
	end
	writeJoints(w, inst, index)
	return w:finish()
end

--[=[
	Rebuilds a snapshot as an anchored, non-colliding Part or Model whose
	pivot matches the original root. A linked prefab is cloned instead, with
	its pivot moved to the part at the recorded root's path (or name) so
	recorded transforms land where the original did.
	@within Snapshot
]=]
function Snapshot.build(data: buffer): Instance
	local r = Serializer.newReader(data)
	local version = r:u8()
	assert(version == VERSION, `unsupported snapshot version {version}`)
	local isModel = r:u8() == 1
	local name = r:str16()
	local source = r:str16()
	local rootPath = r:str16()
	local prefab = Snapshot.links[source]
	local clone = if prefab then prefab:Clone() else nil
	if prefab and not clone then
		warn(`Flashback: linked prefab {prefab:GetFullName()} is not Archivable; rebuilding {name} from its snapshot`)
	end
	if clone then
		if clone:IsA("Model") then
			local rootName = rootPath:match("[^/]+$") or rootPath
			local pivotPart = Snapshot.resolve(clone, rootPath) or clone:FindFirstChild(rootName, true)
			local root = if pivotPart and pivotPart:IsA("BasePart") then pivotPart else rootOf(clone)
			if root then
				root.PivotOffset = CFrame.identity
				clone.PrimaryPart = root
			end
		elseif clone:IsA("BasePart") then
			clone.PivotOffset = CFrame.identity
		end
		return clone
	end
	local unionKeys: { string } = {}
	for i = 1, r:u16() do
		unionKeys[i] = r:str16()
	end
	for _ = 1, r:u16() do
		r:str16()
	end
	local model: Model? = nil
	if isModel then
		model = Instance.new("Model")
		readRig(r, model :: Model)
	end
	local count = r:u16()
	local built: { BasePart } = {}
	local refs: { PendingRef } = {}
	for _ = 1, count do
		local kind = r:u8()
		local union = if kind == KIND_UNION then Snapshot.resolveUnion(unionKeys[r:u16()]) else nil
		local partName = r:str16()
		local path = r:str16()
		local pos = readVector(r)
		local rot = Serializer.readRotation(r)
		local size = readVector(r)
		local color = readColor(r)
		local materialValue = r:u16()
		local transparency = r:u8() / 255
		local reflectance = r:u8() / 255
		local shapeValue = r:u8()
		local surfaces = {}
		for i = 1, #SURFACE_PROPS do
			surfaces[i] = r:u8()
		end
		local meshId, textureId, meshSize = "", "", Vector3.zero
		if kind == KIND_MESH then
			meshId, textureId = r:str16(), r:str16()
			meshSize = readVector(r)
		end
		local cached = if kind == KIND_MESH then meshTemplates[meshId] else nil
		local meshTemplate: MeshPart? = if cached then (cached :: any) :: MeshPart else nil
		local part: BasePart
		local unionCopy = if union then union:Clone() else nil
		if unionCopy then
			unionCopy:ClearAllChildren()
			part = unionCopy
		elseif meshTemplate then
			local meshPart = meshTemplate:Clone()
			meshPart.TextureID = textureId
			part = meshPart
		elseif kind == KIND_WEDGE then
			part = Instance.new("WedgePart")
		elseif kind == KIND_CORNER_WEDGE then
			part = Instance.new("CornerWedgePart")
		else
			local p = Instance.new("Part")
			if kind == KIND_PART then
				local shape = enumByValue(Enum.PartType, shapeValue)
				if shape then
					p.Shape = shape :: Enum.PartType
				end
			end
			part = p
		end
		if kind == KIND_MESH and not meshTemplate then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.FileMesh
			mesh.MeshId = meshId
			mesh.TextureId = textureId
			mesh.Scale = Vector3.new(
				if meshSize.X > 0 then size.X / meshSize.X else 1,
				if meshSize.Y > 0 then size.Y / meshSize.Y else 1,
				if meshSize.Z > 0 then size.Z / meshSize.Z else 1
			)
			mesh.Parent = part
		end
		part.Name = partName
		part.Size = size
		part.Color = color
		local material = enumByValue(Enum.Material, materialValue)
		if material then
			part.Material = material :: Enum.Material
		end
		part.Transparency = transparency
		part.Reflectance = reflectance
		for i, prop in SURFACE_PROPS do
			local surface = enumByValue(Enum.SurfaceType, surfaces[i])
			if surface then
				(part :: any)[prop] = surface
			end
		end
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CFrame = CFrame.new(pos) * rot
		readSpecialMesh(r, part)
		readSurfaceAppearance(r, part)
		readDecals(r, part)
		readEffects(r, part, refs)
		table.insert(built, part)
		local top: Instance? = model or built[1]
		if top and part ~= top then
			part.Parent = containerAt(top, path)
		end
	end
	readJoints(r, built)
	local rootInst: Instance = if model then model else built[1]
	if model then
		model.Name = name
	end
	for _, ref in refs do
		local target = rootInst:FindFirstChild(ref.target, true)
		if target and target:IsA("Attachment") then
			(ref.inst :: any)[ref.name] = target
		end
	end
	if not model then
		return built[1]
	end
	model.PrimaryPart = built[1]
	return model
end

return Snapshot

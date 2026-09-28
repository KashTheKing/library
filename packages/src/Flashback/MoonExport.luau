--!strict
--[=[
	@class MoonExport
	Exports a loaded replay as a Moon Animator 2 save. The player is stepped
	through every tick in edit mode and each proxy is sampled: its pivot
	becomes a CFrame track and every Motor6D becomes a rig joint track
	(Moon stores joint keys as C1 values, so Transform is folded into C1).
	Recorded property changes (effects, sounds, appearance) become property
	tracks on items for the instances they touched, with constant eases.
	Moon items cannot enter or leave the scene, so an entity that spawns or
	despawns mid-replay has every part's Transparency toggled instead. An
	entity whose snapshot is linked to a prefab (`Snapshot.links`) uses that
	prefab as its Moon item; anything else is copied into Workspace so Moon
	can resolve the item path. The save lands in
	ServerStorage.MoonAnimator2Saves where Moon's File > Open lists it.
]=]

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local Player = require(script.Parent.Player)
local Snapshot = require(script.Parent.Snapshot)

local FPS = 60
local MIN_FRAMES = 60

type Track = {
	default: any,
	enumType: string?,
	frames: { [number]: any },
	lastFrame: number?,
	lastValue: any,
	lastWritten: number?,
}
type Item = { rig: Instance, joints: { [string]: Track }, cframe: Track, props: { [Instance]: { [string]: Track } } }

local MoonExport = {}

local function newTrack(default: any): Track
	return { default = default, enumType = nil, frames = {}, lastFrame = nil, lastValue = nil, lastWritten = nil }
end

local function same(a: any, b: any): boolean
	if typeof(a) == "CFrame" then
		return a:FuzzyEq(b, 1e-4)
	end
	return a == b
end

-- Writes a key only when the value changes, and closes the preceding hold
-- with a key on its last frame so Moon's linear ease does not drift.
local function sample(track: Track, frame: number, value: any)
	if track.lastFrame == nil then
		track.frames[frame] = value
		track.lastWritten = frame
	elseif not same(value, track.lastValue) then
		if track.lastWritten ~= track.lastFrame then
			track.frames[track.lastFrame :: number] = track.lastValue
		end
		track.frames[frame] = value
		track.lastWritten = frame
	end
	track.lastFrame = frame
	track.lastValue = value
end

-- Adds a discrete change at `frame`, holding the previous value up to the
-- frame before so the change stays a step.
local function change(track: Track, frame: number, value: any)
	local last = track.lastWritten
	if last and last < frame - 1 then
		track.frames[frame - 1] = track.lastValue
	end
	track.frames[frame] = value
	track.lastWritten = frame
	track.lastValue = value
end

-- Moon addresses a joint by the chain of Part1 names from the rig's root
-- joint, so "Torso.Left Arm" is the shoulder motor of an R6 rig.
local function hierarchyOf(joint: Motor6D, byPart1: { [BasePart]: Motor6D }): string
	local names = { (joint.Part1 :: BasePart).Name }
	local cur = byPart1[joint.Part0 :: BasePart]
	while cur do
		table.insert(names, 1, (cur.Part1 :: BasePart).Name)
		cur = byPart1[cur.Part0 :: BasePart]
	end
	return table.concat(names, ".")
end

local function motorsOf(inst: Instance): ({ Motor6D }, { [BasePart]: Motor6D })
	local motors: { Motor6D } = {}
	local byPart1: { [BasePart]: Motor6D } = {}
	for _, d in inst:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 and d.Part1 then
			table.insert(motors, d)
			byPart1[d.Part1 :: BasePart] = d
		end
	end
	return motors, byPart1
end

local function pivotOf(inst: Instance): CFrame
	return if inst:IsA("Model") then inst:GetPivot() elseif inst:IsA("BasePart") then inst.CFrame else CFrame.identity
end

-- The prefab an entity's snapshot is linked to, when it still exists in the
-- place and no earlier entity claimed it. Rigs need a PrimaryPart for Moon.
local function linkedPrefab(e: Player.Entity, used: { [Instance]: boolean }): Instance?
	if not e.snapshot then
		return nil
	end
	local prefab = Snapshot.links[Snapshot.keys(e.snapshot).source]
	if not prefab or used[prefab] or not prefab:IsDescendantOf(game) then
		return nil
	end
	used[prefab] = true
	if prefab:IsA("Model") and not prefab.PrimaryPart then
		prefab.PrimaryPart = prefab:FindFirstChildWhichIsA("BasePart", true)
	end
	return prefab
end

local function copyToWorkspace(proxy: Instance, name: string): Instance
	local flipped = { proxy }
	for _, d in proxy:GetDescendants() do
		table.insert(flipped, d)
	end
	for _, inst in flipped do
		inst.Archivable = true
	end
	local rig = proxy:Clone()
	for _, inst in flipped do
		inst.Archivable = false
	end
	rig.Name = name
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") then
			d.Transform = CFrame.identity
		end
	end
	if rig:IsA("Model") and not rig.PrimaryPart then
		rig.PrimaryPart = rig:FindFirstChildWhichIsA("BasePart", true)
	end
	rig.Parent = workspace
	return rig
end

local VALUE_CLASS = {
	CFrame = "CFrameValue",
	number = "NumberValue",
	boolean = "BoolValue",
	string = "StringValue",
	Color3 = "Color3Value",
	Vector3 = "Vector3Value",
}

local function valueInstance(name: string, value: any): ValueBase
	local inst: ValueBase = Instance.new(VALUE_CLASS[typeof(value)] or "StringValue") :: any
	inst.Name = name
	local any: any = inst
	any.Value = if VALUE_CLASS[typeof(value)] then value else tostring(value)
	return inst
end

local function enumTag(enumType: string?, parent: Instance)
	if enumType then
		local tag = Instance.new("StringValue")
		tag.Name = "EnumType"
		tag.Value = enumType
		tag.Parent = parent
	end
end

local function folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function writeTrack(track: Track, parent: Instance, withDefault: boolean, ease: string)
	if withDefault then
		local default = valueInstance("default", track.default)
		enumTag(track.enumType, default)
		default.Parent = parent
	end
	for frame, value in track.frames do
		local key = folder(tostring(frame), parent)
		local values = folder("Values", key)
		valueInstance("0", value).Parent = values
		enumTag(track.enumType, values)
		local easeFolder = folder("0", folder("Eases", key))
		local kind = Instance.new("StringValue")
		kind.Name = "Type"
		kind.Value = ease
		kind.Parent = easeFolder
		folder("Params", easeFolder)
	end
end

-- Moon item path from the DataModel down to an instance.
local function pathTo(inst: Instance): ({ string }, { string })
	local names, types = {}, {}
	local cur: Instance? = inst
	while cur and cur ~= game do
		table.insert(names, 1, cur.Name)
		table.insert(types, 1, cur.ClassName)
		cur = cur.Parent
	end
	table.insert(names, 1, "game")
	table.insert(types, 1, "DataModel")
	return names, types
end

local function propTrack(item: Item, target: Instance, prop: string, default: any): Track
	local tracks = item.props[target]
	if not tracks then
		tracks = {}
		item.props[target] = tracks
	end
	local track = tracks[prop]
	if not track then
		local created = newTrack(default)
		tracks[prop] = created
		change(created, 0, default)
		track = created
	end
	return track :: Track
end

-- Hides every part of an entity outside its lifetime.
local function collectLifetime(item: Item, spawnFrame: number, despawnFrame: number?)
	if spawnFrame == 0 and not despawnFrame then
		return
	end
	local parts = item.rig:GetDescendants()
	table.insert(parts, item.rig)
	for _, part in parts do
		if not part:IsA("BasePart") then
			continue
		end
		local track = propTrack(item, part, "Transparency", if spawnFrame > 0 then 1 else part.Transparency)
		if spawnFrame > 0 then
			change(track, spawnFrame, part.Transparency)
		end
		if despawnFrame then
			change(track, despawnFrame, 1)
		end
	end
end

-- Turns an entity's recorded property changes into tracks on the copied
-- instances they touched. Attributes and model scale have no Moon track.
local function collectProps(item: Item, props: { [number]: { any } }, frameOf: (number) -> number)
	local ticks = {}
	for tick in props do
		table.insert(ticks, tick)
	end
	table.sort(ticks)
	for _, tick in ticks do
		for _, p in props[tick] do
			local name: string = p.name
			local segments = name:split("/")
			local prop = table.remove(segments) :: string
			if prop:sub(1, 1) == "@" or prop == "Scale" then
				continue
			end
			local target = Snapshot.resolve(item.rig, table.concat(segments, "/"))
			if not target then
				continue
			end
			local ok, current = pcall(function()
				return (target :: any)[prop]
			end)
			if not ok then
				continue
			end
			local isEnum = typeof(current) == "EnumItem"
			local track = propTrack(item, target, prop, if isEnum then current.Name else current)
			track.enumType = if isEnum then tostring(current.EnumType) else nil
			change(track, frameOf(tick), p.value)
		end
	end
end

--[=[
	Steps `player` from its first tick to its last and writes the save. Only
	meaningful in edit mode, where the player advances animators itself.
	Returns the save StringValue.
	@within MoonExport
]=]
function MoonExport.export(player: Player.Player, name: string): StringValue
	local tickRate = math.max(1, math.min(player.header.tickRate, FPS))
	local tickCount = player:tickCount()
	local items: { [number]: Item } = {}
	local order: { number } = {}
	local usedPrefabs: { [Instance]: boolean } = {}

	player:pause()
	player:setReverse(false)
	player:setLoop(false)
	player:setSpeed(1)
	player:seek(1)
	player:play()
	local lastFrame = 0
	for tick = 1, tickCount do
		local frame = math.round((tick - 1) * FPS / tickRate)
		lastFrame = frame
		for id, e in player:getEntities() do
			local proxy = e.proxy
			if not proxy or not e.ownsProxy then
				continue
			end
			local item = items[id]
			if not item then
				item = {
					rig = linkedPrefab(e, usedPrefabs) or copyToWorkspace(proxy, `{name}_E{id}`),
					joints = {},
					cframe = newTrack(pivotOf(proxy)),
					props = {},
				}
				items[id] = item
				table.insert(order, id)
			end
			sample(item.cframe, frame, pivotOf(proxy))
			local motors, byPart1 = motorsOf(proxy)
			for _, motor in motors do
				local hier = hierarchyOf(motor, byPart1)
				local track = item.joints[hier]
				if not track then
					track = newTrack(motor.C1)
					item.joints[hier] = track
				end
				sample(track, frame, motor.C1 * motor.Transform:Inverse())
			end
		end
		player:step(1 / tickRate)
	end
	player:pause()
	player:seek(1)
	local function frameOf(tick: number): number
		return math.round((tick - 1) * FPS / tickRate)
	end
	for id, item in items do
		local e = player:getEntities()[id]
		collectLifetime(item, frameOf(e.spawnTick), if e.despawnTick then frameOf(e.despawnTick) else nil)
		collectProps(item, e.props :: any, frameOf)
	end

	local saveItems = {}
	local save = Instance.new("StringValue")
	save.Name = name
	for i, id in order do
		local item = items[id]
		local isRig = next(item.joints) ~= nil
		local names, types = pathTo(item.rig)
		table.insert(saveItems, {
			Path = {
				ItemType = if isRig then "Rig" else item.rig.ClassName,
				InstanceTypes = types,
				InstanceNames = names,
			},
		})
		local itemFolder = folder(tostring(i), save)
		if isRig then
			local rigFolder = folder("Rig", itemFolder)
			for hier, track in item.joints do
				local jointFolder = folder("_joint", rigFolder)
				local hierValue = Instance.new("StringValue")
				hierValue.Name = "_hier"
				hierValue.Value = hier
				hierValue.Parent = jointFolder
				valueInstance("default", track.default).Parent = jointFolder
				writeTrack(track, folder("_keyframes", jointFolder), false, "Linear")
			end
			folder("MarkerTrack", itemFolder)
		end
		writeTrack(item.cframe, folder("CFrame", itemFolder), true, "Linear")
	end
	for _, id in order do
		for target, tracks in items[id].props do
			local names, types = pathTo(target)
			table.insert(
				saveItems,
				{ Path = { ItemType = target.ClassName, InstanceTypes = types, InstanceNames = names } }
			)
			local itemFolder = folder(tostring(#saveItems), save)
			for prop, track in tracks do
				writeTrack(track, folder(prop, itemFolder), true, "Constant")
			end
		end
	end
	local now = os.time()
	save.Value = HttpService:JSONEncode({
		Information = {
			Created = now,
			Modified = now,
			Length = math.max(MIN_FRAMES, lastFrame),
			FPS = FPS,
			Looped = false,
			ExportPriority = "Action",
		},
		Items = saveItems,
	})
	local saves = ServerStorage:FindFirstChild("MoonAnimator2Saves") or folder("MoonAnimator2Saves", ServerStorage)
	save.Parent = saves
	return save
end

return MoonExport

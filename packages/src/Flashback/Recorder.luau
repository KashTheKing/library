--!strict
--[=[
	@class Recorder
	Server-side recorder. Tracks tagged instances and writes transforms,
	spawn/despawn, watched properties, animations, gameplay events and custom
	channels into a replay buffer.

	Transforms are delta-compressed: after a full sample, each moving tick costs
	a few bytes of quantized position delta plus a yaw delta for upright
	entities. Parts jointed to a tracked ancestor (character limbs, welded
	attachments) are not written at all; the playback rig's own joints and
	animations move them.
]=]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Serializer = require(script.Parent.Serializer)
local Snapshot = require(script.Parent.Snapshot)

local Op = Serializer.Op
local PT = Serializer.PropType
local POS_Q = Serializer.POS_Q
local YAW_Q = Serializer.YAW_Q
local ROT_Q = Serializer.ROT_Q
local Delta = Serializer.Delta

local TAG = "FlashbackTracked"
local DESCRIPTOR_ATTRIBUTE = "FlashbackDescriptor"
local WATCH_ATTRIBUTE = "FlashbackWatch"
local ANIMATIONS_ATTRIBUTE = "FlashbackAnimations"
local ATTRIBUTES_ATTRIBUTE = "FlashbackAttributes"
local SCALE_ATTRIBUTE = "FlashbackScale"
local DESCENDANTS_ATTRIBUTE = "FlashbackDescendants"
local POS_EPS = 1 / POS_Q
local YAW_EPS = 1 / YAW_Q
local SPEED_EPS = 0.05

export type Options = {
	tickRate: number?,
	keyframeEvery: number?,
	trackCharacters: boolean?,
	watch: string?,
	recordAnimations: boolean?,
	recordAttributes: boolean?,
	recordScale: boolean?,
	recordDescendants: boolean?,
}

-- Options:
-- - `tickRate` snapshots per second (default 15)
-- - `keyframeEvery` ticks between full transforms (default 300)
-- - `trackCharacters` tag player characters and their limbs automatically
-- (default true); set false to record only tagged instances
-- - `watch` the properties to follow, as a `Class.Property` list (default
-- `Recorder.DEFAULT_WATCH`: part appearance, humanoid health and the
-- on/off state of effects); `watchProperties` overrides one class
-- - `recordAnimations` capture animation tracks played on tracked models
-- (default true)
-- - `recordAttributes` record every attribute of tracked instances
-- (default false)
-- - `recordScale` record `Model:GetScale()` changes of tracked models
-- (default false)
-- - `recordDescendants` follow watched properties and effect state on the
-- descendants of tracked instances (default true); off records only the
-- entity's own transform, properties, attributes and scale
--
-- Any tracked instance can override these with attributes of its own:
-- `FlashbackWatch` (a watch list, see `parseWatch`), `FlashbackAnimations`,
-- `FlashbackAttributes`, `FlashbackScale` and `FlashbackDescendants`
-- (booleans).

export type ChannelWriter = (Serializer.Writer, number) -> ()

type Entity = {
	id: number,
	inst: Instance,
	root: BasePart?,
	jointed: boolean,
	sub: boolean,
	lastPos: Vector3?,
	lastYaw: number?,
	lastRot: CFrame?,
	lastProps: { [Instance]: { [string]: any } },
	conns: { RBXScriptConnection },
	nextHandle: number,
	liveTracks: { [AnimationTrack]: number },
	effects: { Instance },
	joints: { Instance },
	parent: Entity?,
	soundPlays: { [Instance]: boolean },
	snapshot: buffer?,
	snapshotDue: number?,
	watched: { [string]: { string } },
	animations: boolean,
	attributes: boolean,
	scale: boolean,
	descendants: boolean,
	scale0: number,
}

-- Part properties the snapshot already carries, so their initial values are
-- never written as PROP ops; only later changes are.
local SNAPSHOT_PART_PROPS: { [string]: boolean } = {
	Color = true,
	Transparency = true,
	Size = true,
	Material = true,
	Reflectance = true,
}

-- Effect properties in the default watch list, written as PROP ops
-- addressed by path inside the entity (`Body/Exhaust/Enabled`). Static
-- appearance is captured once by the snapshot, so these classes never
-- write their initial values.
local EFFECT_STATE: { [string]: { string } } = {
	Sound = { "Playing", "Volume", "PlaybackSpeed" },
	ParticleEmitter = { "Enabled", "Rate" },
	Beam = { "Enabled" },
	Trail = { "Enabled" },
	Fire = { "Enabled", "Size", "Heat" },
	Smoke = { "Enabled", "Size", "Opacity" },
	Sparkles = { "Enabled" },
	PointLight = { "Enabled", "Brightness", "Range" },
	SpotLight = { "Enabled", "Brightness", "Range" },
	SurfaceLight = { "Enabled", "Brightness", "Range" },
}

local DEFAULT_WATCH_ENTRIES = {
	"BasePart.Color",
	"BasePart.Transparency",
	"BasePart.Size",
	"BasePart.Material",
	"Humanoid.Health",
	"Humanoid.MaxHealth",
}
for className, props in EFFECT_STATE do
	for _, prop in props do
		table.insert(DEFAULT_WATCH_ENTRIES, `{className}.{prop}`)
	end
end
table.sort(DEFAULT_WATCH_ENTRIES)

-- Slash path of `inst` inside its entity, with `#n` on ambiguous segments.
-- Rebuilt proxies keep the same hierarchy (wrappers such as Accessory come
-- back as Folders), so the path resolves on playback as it did when
-- recorded.
local pathWithin = Snapshot.pathWithin

type Fields = {
	tickRate: number,
	keyframeEvery: number,
	trackCharacters: boolean,
	recordAnimations: boolean,
	recordAttributes: boolean,
	recordScale: boolean,
	recordDescendants: boolean,
	strings: Serializer.StringTable,
	ops: Serializer.Writer,
	keyframes: { { tick: number, offset: number } },
	entities: { [Instance]: Entity },
	nextEntityId: number,
	tick: number,
	running: boolean,
	startUnix: number,
	watched: { [string]: { string } },
	channels: { [string]: ChannelWriter },
	conns: { RBXScriptConnection },
	pendingEvents: { { name: string, payload: string } },
	pendingCustom: { { channel: string, data: buffer } },
	accumulator: number,
	lastTickWritten: number,
}

local Recorder = {}
Recorder.__index = Recorder

export type Recorder = typeof(setmetatable({} :: Fields, Recorder))

Recorder.TAG = TAG
Recorder.DESCRIPTOR_ATTRIBUTE = DESCRIPTOR_ATTRIBUTE
Recorder.WATCH_ATTRIBUTE = WATCH_ATTRIBUTE
Recorder.ANIMATIONS_ATTRIBUTE = ANIMATIONS_ATTRIBUTE
Recorder.ATTRIBUTES_ATTRIBUTE = ATTRIBUTES_ATTRIBUTE
Recorder.SCALE_ATTRIBUTE = SCALE_ATTRIBUTE
Recorder.DESCENDANTS_ATTRIBUTE = DESCENDANTS_ATTRIBUTE
Recorder.DEFAULT_WATCH = table.concat(DEFAULT_WATCH_ENTRIES, ",")

--[=[
	Parses a watch list such as `BasePart.Color,Humanoid.Health` into the
	class -> properties table `watchProperties` uses.
	@within Recorder
]=]
function Recorder.parseWatch(list: string): { [string]: { string } }
	local watched: { [string]: { string } } = {}
	for entry in list:gmatch("[^,]+") do
		local className, prop = entry:match("^%s*([%w_]+)%.([%w_]+)%s*$")
		if className and prop then
			local props = watched[className]
			if not props then
				props = {}
				watched[className] = props
			end
			if not table.find(props, prop) then
				table.insert(props, prop)
			end
		end
	end
	return watched
end

function Recorder.new(opts: Options?): Recorder
	local o: Options = opts or {}
	local fields: Fields = {
		tickRate = o.tickRate or 15,
		keyframeEvery = o.keyframeEvery or 300,
		trackCharacters = o.trackCharacters ~= false,
		recordAnimations = o.recordAnimations ~= false,
		recordAttributes = o.recordAttributes == true,
		recordScale = o.recordScale == true,
		recordDescendants = o.recordDescendants ~= false,
		strings = Serializer.newStringTable(),
		ops = Serializer.newWriter(65536),
		keyframes = {},
		entities = {},
		nextEntityId = 1,
		tick = 0,
		running = false,
		startUnix = 0,
		watched = Recorder.parseWatch(o.watch or Recorder.DEFAULT_WATCH),
		channels = {},
		conns = {},
		pendingEvents = {},
		pendingCustom = {},
		accumulator = 0,
		lastTickWritten = 0,
	}
	return setmetatable(fields, Recorder)
end

--[=[
	Records the named properties of every tracked instance that IsA className.
	Initial values are written on spawn and changes are written each tick.
	Limbs and other jointed sub-parts are skipped; their look comes from the
	playback rig.
	@within Recorder
]=]
function Recorder.watchProperties(self: Recorder, className: string, props: { string })
	self.watched[className] = props
end

--[=[
	Registers a per-tick binary writer. The player must register a reader for
	the same channel name.
	@within Recorder
]=]
function Recorder.registerChannel(self: Recorder, name: string, writer: ChannelWriter)
	self.channels[name] = writer
end

--[=[
	Queues a discrete gameplay event. The payload is JSON encoded and delivered
	to player-side handlers registered with the same name.
	@within Recorder
]=]
function Recorder.event(self: Recorder, name: string, payload: { [string]: any }?)
	if not self.running then
		return
	end
	table.insert(self.pendingEvents, { name = name, payload = HttpService:JSONEncode(payload or {}) })
end

--[=[
	Queues an ad-hoc binary payload on a channel.
	@within Recorder
]=]
function Recorder.custom(self: Recorder, channel: string, data: buffer)
	if not self.running then
		return
	end
	table.insert(self.pendingCustom, { channel = channel, data = data })
end

--[=[
	Explicitly tracks an instance without tagging it.
	@within Recorder
]=]
function Recorder.track(self: Recorder, inst: Instance)
	if self.running then
		self:_track(inst)
	else
		inst:AddTag(TAG)
	end
end

function Recorder.untrack(self: Recorder, inst: Instance)
	inst:RemoveTag(TAG)
	self:_untrack(inst)
end

local function descriptorFor(inst: Instance, parent: Instance?): string
	local d = inst:GetAttribute(DESCRIPTOR_ATTRIBUTE)
	if typeof(d) == "string" then
		return d
	end
	if parent then
		return "sub:" .. (pathWithin(inst, parent) or inst.Name)
	end
	if inst:IsA("Model") then
		local player = Players:GetPlayerFromCharacter(inst)
		if player then
			return "char:" .. player.UserId
		end
	end
	if inst:IsA("Part") then
		return "part:" .. inst.Shape.Name
	end
	if inst:IsA("BasePart") then
		return "part:" .. inst.ClassName
	end
	return "model:" .. inst.Name
end

local rootOf = Snapshot.rootOf

local function attachedPart(att: Attachment?): Instance?
	return if att then att.Parent else nil
end

-- The joints holding a part to its assembly: Motor6D/Weld, WeldConstraint,
-- or the AnimationConstraint/RigidConstraint pairs modern rigs and
-- accessories use. Empty when the part moves on its own.
local function jointsHolding(part: BasePart, container: Instance): { Instance }
	local joints: { Instance } = {}
	for _, d in container:GetDescendants() do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			local joint = d :: any
			if joint.Part0 == part or joint.Part1 == part then
				table.insert(joints, d)
			end
		elseif d:IsA("AnimationConstraint") or d:IsA("RigidConstraint") then
			local c = d :: any
			if attachedPart(c.Attachment0) == part or attachedPart(c.Attachment1) == part then
				table.insert(joints, d)
			end
		end
	end
	return joints
end

function Recorder._track(self: Recorder, inst: Instance)
	if self.entities[inst] then
		return
	end
	local parentEnt: Entity? = nil
	local ancestor = inst.Parent
	while ancestor and not parentEnt do
		parentEnt = self.entities[ancestor]
		ancestor = ancestor.Parent
	end
	local sub = parentEnt ~= nil and inst:IsA("BasePart")
	local joints: { Instance } = if sub then jointsHolding(inst :: BasePart, (parentEnt :: Entity).inst) else {}
	local jointed = #joints > 0
	local function flag(attribute: string, default: boolean): boolean
		local v = inst:GetAttribute(attribute)
		return if typeof(v) == "boolean" then v else default
	end
	local watchList = inst:GetAttribute(WATCH_ATTRIBUTE)
	local e: Entity = {
		id = 0,
		inst = inst,
		root = rootOf(inst),
		jointed = jointed,
		sub = sub,
		lastPos = nil,
		lastYaw = nil,
		lastRot = nil,
		lastProps = {},
		conns = {},
		nextHandle = 1,
		liveTracks = {},
		effects = {},
		joints = joints,
		parent = parentEnt,
		soundPlays = {},
		snapshot = nil,
		snapshotDue = nil,
		watched = if typeof(watchList) == "string" then Recorder.parseWatch(watchList) else self.watched,
		animations = flag(ANIMATIONS_ATTRIBUTE, self.recordAnimations),
		attributes = flag(ATTRIBUTES_ATTRIBUTE, self.recordAttributes),
		scale = flag(SCALE_ATTRIBUTE, self.recordScale),
		descendants = flag(DESCENDANTS_ATTRIBUTE, self.recordDescendants),
		scale0 = if inst:IsA("Model") then inst:GetScale() else 1,
	}
	self.entities[inst] = e
	table.insert(
		e.conns,
		inst.AncestryChanged:Connect(function(_, newParent)
			local parent = e.parent
			if newParent == nil or (parent and not inst:IsDescendantOf(parent.inst)) then
				self:_untrack(inst)
			end
		end)
	)
	if jointed then
		for _, joint in joints do
			table.insert(
				e.conns,
				joint.AncestryChanged:Connect(function(_, newParent)
					if newParent == nil or not newParent:IsDescendantOf((parentEnt :: Entity).inst) then
						self:_recheckJoints(e)
					end
				end)
			)
		end
		return
	end
	self:_spawn(e)
end

--[=[
	Gives a limb its own entity once nothing holds it to the rig any more
	(joints broken on death, a weld destroyed), so its fall is recorded.
	@within Recorder
]=]
function Recorder._recheckJoints(self: Recorder, e: Entity)
	if not e.jointed or self.entities[e.inst] ~= e then
		return
	end
	local parent = e.parent
	if not parent or not e.inst:IsA("BasePart") then
		return
	end
	if #jointsHolding(e.inst :: BasePart, parent.inst) > 0 then
		return
	end
	e.jointed = false
	e.joints = {}
	self:_spawn(e)
end

--[=[
	Writes SPAWN and starts following an entity: props, snapshot, animations,
	tools carried inside it and sounds played on it.
	@within Recorder
]=]
function Recorder._spawn(self: Recorder, e: Entity)
	local inst = e.inst
	local parentEnt = e.parent
	e.id = self.nextEntityId
	self.nextEntityId += 1
	if not e.sub then
		local function watchDescendant(d: Instance)
			if e.descendants and self:_descendantProps(e, d) then
				table.insert(e.effects, d)
				if d:IsA("Sound") then
					table.insert(
						e.conns,
						d.Played:Connect(function()
							e.soundPlays[d] = true
						end)
					)
				end
			end
		end
		for _, d in inst:GetDescendants() do
			watchDescendant(d)
		end
		table.insert(
			e.conns,
			inst.DescendantAdded:Connect(function(d)
				watchDescendant(d)
				e.snapshotDue = self.tick + self.tickRate
			end)
		)
		table.insert(
			e.conns,
			inst.ChildAdded:Connect(function(child)
				if child:IsA("Tool") then
					self:_track(child)
				end
			end)
		)
	end

	self:_writeTick()
	self.ops:u8(Op.SPAWN)
	self.ops:u16(e.id)
	self.ops:u16(self.strings.intern(descriptorFor(inst, if e.sub then (parentEnt :: Entity).inst else nil)))
	self.ops:u16(if parentEnt then parentEnt.id else 0)

	if not e.sub then
		self:_writeProps(e, true)
		if parentEnt then
			parentEnt.snapshotDue = self.tick + self.tickRate
		end
		e.snapshot = self:_capture(e)
	end

	local animator = if inst:IsA("Model") and e.animations then inst:FindFirstChildWhichIsA("Animator", true) else nil
	if animator then
		table.insert(
			e.conns,
			animator.AnimationPlayed:Connect(function(track)
				self:_animPlayed(e, track)
			end)
		)
		for _, track in animator:GetPlayingAnimationTracks() do
			self:_animPlayed(e, track)
		end
	end

	if not e.sub then
		for _, child in inst:GetChildren() do
			if child:IsA("Tool") then
				self:_track(child)
			end
		end
	end
end

--[=[
	Snapshot of an entity without the geometry of entities carried inside it
	(an equipped tool), which have snapshots of their own.
	@within Recorder
]=]
function Recorder._capture(self: Recorder, e: Entity): buffer?
	return Snapshot.capture(e.inst, function(d: Instance): boolean
		local other = self.entities[d]
		return other ~= nil and other ~= e and not other.sub
	end)
end

function Recorder._untrack(self: Recorder, inst: Instance)
	local e = self.entities[inst]
	if not e then
		return
	end
	for _, c in e.conns do
		c:Disconnect()
	end
	self.entities[inst] = nil
	if e.jointed then
		return
	end
	if not e.sub then
		self:_flushSnapshot(e)
	end
	self:_writeTick()
	self.ops:u8(Op.DESPAWN)
	self.ops:u16(e.id)
	for _, other in self.entities do
		if other.parent == e then
			self:_untrack(other.inst)
		end
	end
end

local function speedUnits(speed: number): number
	return math.clamp(math.round(speed * 256), -32768, 32767)
end

function Recorder._animPlayed(self: Recorder, e: Entity, track: AnimationTrack)
	local anim = track.Animation
	if not anim or e.liveTracks[track] then
		return
	end
	local handle = e.nextHandle
	e.nextHandle = (handle % 255) + 1
	e.liveTracks[track] = handle

	self:_writeTick()
	self.ops:u8(Op.ANIM_PLAY)
	self.ops:u16(e.id)
	self.ops:u16(self.strings.intern(anim.AnimationId))
	self.ops:u8(handle)
	self.ops:u8(10)
	self.ops:i16(speedUnits(track.Speed))

	local lastSpeed = track.Speed
	table.insert(
		e.conns,
		track:GetPropertyChangedSignal("Speed"):Connect(function()
			if math.abs(track.Speed - lastSpeed) > SPEED_EPS then
				lastSpeed = track.Speed
				self:_writeTick()
				self.ops:u8(Op.ANIM_SPEED)
				self.ops:u16(e.id)
				self.ops:u8(handle)
				self.ops:i16(speedUnits(track.Speed))
			end
		end)
	)
end

--[=[
	Tracks are polled each tick instead of trusting `Stopped`, which does
	not fire reliably for tracks replicated from a client, so a stop lands
	within one tick of the track going idle.
	@within Recorder
]=]
function Recorder._pollTracks(self: Recorder, e: Entity)
	for track, handle in e.liveTracks do
		if not track.IsPlaying then
			e.liveTracks[track] = nil
			self:_writeTick()
			self.ops:u8(Op.ANIM_STOP)
			self.ops:u16(e.id)
			self.ops:u8(handle)
			self.ops:u8(10)
		end
	end
end

--[=[
	Writes the entity's geometry once. The capture taken at spawn is held
	back while descendants keep arriving (a character still loading limbs
	and accessories) and replaced by a fresh capture once the entity has
	been quiet for a second, so a replay carries one snapshot per entity
	instead of one per arrival. Pending captures are flushed on untrack,
	stop and finalize; the player keeps the last snapshot it decodes.
	@within Recorder
]=]
function Recorder._flushSnapshot(self: Recorder, e: Entity)
	if e.snapshotDue then
		e.snapshotDue = nil
		local ok, fresh = pcall(self._capture, self, e)
		e.snapshot = if ok and fresh then fresh else e.snapshot
	end
	local snapshot = e.snapshot
	if snapshot then
		e.snapshot = nil
		self:_writeTick()
		self.ops:u8(Op.SNAPSHOT)
		self.ops:u16(e.id)
		self.ops:u32(buffer.len(snapshot))
		self.ops:buffer(snapshot)
	end
end

--[=[
	Properties the entity's watch list names for an instance: the union of
	every listed class it IsA (so `BasePart.Color` and `Part.Shape` both
	apply to a Part). Nil when nothing matches.
	@within Recorder
]=]
function Recorder._descendantProps(_self: Recorder, e: Entity, d: Instance): { string }?
	local out: { string }? = nil
	for className, watched in e.watched do
		if d:IsA(className) then
			out = out or {}
			for _, prop in watched do
				if not table.find(out :: { string }, prop) then
					table.insert(out :: { string }, prop)
				end
			end
		end
	end
	return out
end

local function propTag(v: any): number?
	local t = typeof(v)
	return if t == "boolean"
		then PT.Bool
		elseif t == "number" then PT.Number
		elseif t == "string" then PT.String
		elseif t == "Color3" then PT.Color3
		elseif t == "Vector3" then PT.Vector3
		elseif t == "EnumItem" then PT.Enum
		else nil
end

--[=[
	Writes one PROP op when the value changed since the last tick. On the
	spawn tick (`force`) values the snapshot already carries are only
	remembered, not written.
	@within Recorder
]=]
function Recorder._writeProp(
	self: Recorder,
	e: Entity,
	inst: Instance,
	name: string,
	key: string,
	v: any,
	force: boolean
)
	local last = e.lastProps[inst]
	if not last then
		last = {}
		e.lastProps[inst] = last
	end
	if not force and last[key] == v then
		return
	end
	if force and ((inst:IsA("BasePart") and SNAPSHOT_PART_PROPS[key]) or EFFECT_STATE[inst.ClassName]) then
		last[key] = v
		return
	end
	local tag = propTag(v)
	if tag == nil then
		return
	end
	last[key] = v
	local ops = self.ops
	self:_writeTick()
	ops:u8(Op.PROP)
	ops:u16(e.id)
	ops:u16(self.strings.intern(name))
	ops:u8(tag)
	if tag == PT.Bool then
		ops:u8(if v then 1 else 0)
	elseif tag == PT.Number then
		ops:f64(v)
	elseif tag == PT.String then
		ops:u16(self.strings.intern(v))
	elseif tag == PT.Color3 then
		ops:u8(math.round(v.R * 255))
		ops:u8(math.round(v.G * 255))
		ops:u8(math.round(v.B * 255))
	elseif tag == PT.Vector3 then
		ops:f32(v.X)
		ops:f32(v.Y)
		ops:f32(v.Z)
	else
		ops:u16(self.strings.intern(v.Name))
	end
end

--[=[
	Watched properties of the entity and its descendants, its attributes
	(written as `@Name`) and, for models, the scale relative to spawn
	(written as `Scale`).
	@within Recorder
]=]
function Recorder._writeProps(self: Recorder, e: Entity, force: boolean)
	if e.sub then
		return
	end
	local targets: { { inst: Instance, prefix: string, props: { string } } } = {}
	local own = self:_descendantProps(e, e.inst)
	if own then
		table.insert(targets, { inst = e.inst, prefix = "", props = own })
	end
	for _, effect in e.effects do
		local path = pathWithin(effect, e.inst)
		local props = self:_descendantProps(e, effect)
		if path and props then
			table.insert(targets, { inst = effect, prefix = path .. "/", props = props })
		end
	end
	for _, target in targets do
		for _, prop in target.props do
			local ok, v = pcall(function()
				return (target.inst :: any)[prop]
			end)
			if ok then
				self:_writeProp(e, target.inst, target.prefix .. prop, prop, v, force)
			end
		end
	end
	if e.attributes then
		for name, v in e.inst:GetAttributes() do
			self:_writeProp(e, e.inst, "@" .. name, "@" .. name, v, force)
		end
	end
	if e.scale and e.inst:IsA("Model") then
		self:_writeProp(e, e.inst, "Scale", "Scale", e.inst:GetScale() / e.scale0, force)
	end
	for sound in e.soundPlays do
		local path = pathWithin(sound, e.inst)
		local last = e.lastProps[sound]
		if path and sound.Parent then
			if last then
				last.Playing = nil
				last.TimePosition = nil
			end
			self:_writeProp(e, sound, path .. "/TimePosition", "TimePosition", 0, false)
			self:_writeProp(e, sound, path .. "/Playing", "Playing", true, false)
		end
	end
	table.clear(e.soundPlays)
end

--[=[
	Emits the tick marker lazily so idle ticks cost nothing.
	@within Recorder
]=]
function Recorder._writeTick(self: Recorder)
	if self.lastTickWritten == self.tick then
		return
	end
	local ops = self.ops
	if self.tick == self.lastTickWritten + 1 then
		ops:u8(Op.TICK_NEXT)
	else
		ops:u8(Op.TICK)
		ops:u32(self.tick)
	end
	self.lastTickWritten = self.tick
end

local function fits(v: number): boolean
	return v >= -127 and v <= 127
end

local function fits16(v: number): boolean
	return v >= -32767 and v <= 32767
end

function Recorder._writeFull(self: Recorder, e: Entity, cf: CFrame, yawOnly: boolean)
	local ops = self.ops
	self:_writeTick()
	ops:u8(Op.XFORM)
	ops:u16(e.id)
	local mask = 1 + (if yawOnly then 4 else 2)
	ops:u8(mask)
	ops:f32(cf.X)
	ops:f32(cf.Y)
	ops:f32(cf.Z)
	if yawOnly then
		local q = Serializer.quantizeYaw(Serializer.yawOf(cf))
		ops:i16(q)
		e.lastYaw = Serializer.dequantizeYaw(q)
		e.lastRot = nil
	else
		Serializer.writeRotation(ops, cf)
		e.lastYaw = nil
		e.lastRot = cf.Rotation
	end
	e.lastPos = cf.Position
end

function Recorder._writeXform(self: Recorder, e: Entity, cf: CFrame, keyframe: boolean)
	local yawOnly = Serializer.isYawOnly(cf)
	local lastPos = e.lastPos
	if keyframe or not lastPos then
		self:_writeFull(e, cf, yawOnly)
		return
	end

	local dp = cf.Position - lastPos
	local dx = math.round(dp.X * POS_Q)
	local dy = math.round(dp.Y * POS_Q)
	local dz = math.round(dp.Z * POS_Q)
	local mask = 0
	if dp.Magnitude > POS_EPS then
		if fits(dx) and fits(dy) and fits(dz) then
			mask = Delta.POS8
		elseif fits16(dx) and fits16(dy) and fits16(dz) then
			mask = Delta.POS16
		else
			self:_writeFull(e, cf, yawOnly)
			return
		end
	end

	local dyaw = 0
	local rx, ry, rz = 0, 0, 0
	local lastRot = e.lastRot
	if yawOnly and e.lastYaw ~= nil then
		local delta = Serializer.wrapAngle(Serializer.yawOf(cf) - (e.lastYaw :: number))
		dyaw = math.round(delta * YAW_Q)
		if math.abs(delta) > YAW_EPS then
			if not fits(dyaw) then
				self:_writeFull(e, cf, yawOnly)
				return
			end
			mask += Delta.YAW
		end
	elseif not yawOnly and lastRot then
		local axis, angle = (lastRot:Inverse() * cf.Rotation):ToAxisAngle()
		local v = axis * angle * ROT_Q
		rx, ry, rz = math.round(v.X), math.round(v.Y), math.round(v.Z)
		if rx ~= 0 or ry ~= 0 or rz ~= 0 then
			if not (fits(rx) and fits(ry) and fits(rz)) then
				self:_writeFull(e, cf, yawOnly)
				return
			end
			mask += Delta.ROT
		end
	else
		self:_writeFull(e, cf, yawOnly)
		return
	end

	if mask == 0 then
		return
	end
	local ops = self.ops
	self:_writeTick()
	ops:u8(Op.XFORM_D)
	ops:id(e.id)
	ops:u8(mask)
	if bit32.band(mask, Delta.POS8) ~= 0 then
		ops:i8(dx)
		ops:i8(dy)
		ops:i8(dz)
		e.lastPos = lastPos + Vector3.new(dx, dy, dz) / POS_Q
	elseif bit32.band(mask, Delta.POS16) ~= 0 then
		ops:i16(dx)
		ops:i16(dy)
		ops:i16(dz)
		e.lastPos = lastPos + Vector3.new(dx, dy, dz) / POS_Q
	end
	if bit32.band(mask, Delta.YAW) ~= 0 then
		ops:i8(dyaw)
		e.lastYaw = Serializer.wrapAngle((e.lastYaw :: number) + dyaw / YAW_Q)
	end
	if bit32.band(mask, Delta.ROT) ~= 0 then
		ops:i8(rx)
		ops:i8(ry)
		ops:i8(rz)
		e.lastRot = (lastRot :: CFrame) * Serializer.rotationFromDelta(rx, ry, rz)
	end
end

--[=[
	Writes one tick. Called automatically while running, and callable directly
	for deterministic stepping.
	@within Recorder
]=]
function Recorder.snapshot(self: Recorder)
	self.tick += 1
	local keyframe = (self.tick % self.keyframeEvery) == 1 or self.keyframeEvery == 1
	if keyframe then
		table.insert(self.keyframes, { tick = self.tick, offset = self.ops.pos })
	end

	for _, e in self.entities do
		if not e.jointed then
			local root = e.root
			if not root or root.Parent == nil then
				root = rootOf(e.inst)
				e.root = root
			end
			if root then
				self:_writeXform(e, root.CFrame, keyframe)
			end
		end
		if e.snapshotDue and self.tick >= e.snapshotDue then
			self:_flushSnapshot(e)
		end
		self:_writeProps(e, false)
		self:_pollTracks(e)
	end

	local ops = self.ops
	for _, ev in self.pendingEvents do
		self:_writeTick()
		ops:u8(Op.EVENT)
		ops:u16(self.strings.intern(ev.name))
		ops:u16(self.strings.intern(ev.payload))
	end
	table.clear(self.pendingEvents)

	for name, writer in self.channels do
		local scratch = Serializer.newWriter(256)
		writer(scratch, self.tick)
		if scratch.pos > 0 then
			self:_writeTick()
			ops:u8(Op.CUSTOM)
			ops:u16(self.strings.intern(name))
			ops:u16(scratch.pos)
			ops:buffer(scratch:finish())
		end
	end
	for _, c in self.pendingCustom do
		self:_writeTick()
		ops:u8(Op.CUSTOM)
		ops:u16(self.strings.intern(c.channel))
		ops:u16(buffer.len(c.data))
		ops:buffer(c.data)
	end
	table.clear(self.pendingCustom)
end

--[=[
	Advances the recorder clock by dt seconds, emitting as many ticks as elapsed.
	@within Recorder
]=]
function Recorder.step(self: Recorder, dt: number)
	local interval = 1 / self.tickRate
	self.accumulator += dt
	while self.accumulator >= interval do
		self.accumulator -= interval
		self:snapshot()
	end
end

function Recorder.start(self: Recorder)
	assert(not self.running, "already recording")
	self.running = true
	self.startUnix = os.time()

	local tagged = CollectionService:GetTagged(TAG)
	local depth: { [Instance]: number } = {}
	for _, inst in tagged do
		depth[inst] = #inst:GetFullName():split(".")
	end
	table.sort(tagged, function(a, b)
		return depth[a] < depth[b]
	end)
	for _, inst in tagged do
		self:_track(inst)
	end
	table.insert(
		self.conns,
		CollectionService:GetInstanceAddedSignal(TAG):Connect(function(i)
			self:_track(i)
		end)
	)
	table.insert(
		self.conns,
		CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(i)
			self:_untrack(i)
		end)
	)

	if self.trackCharacters then
		local function onChar(char: Model)
			char:AddTag(TAG)
			for _, d in char:GetChildren() do
				if d:IsA("BasePart") then
					d:AddTag(TAG)
				end
			end
			table.insert(
				self.conns,
				char.ChildAdded:Connect(function(d)
					if d:IsA("BasePart") then
						d:AddTag(TAG)
					end
				end)
			)
		end
		local function onPlayer(p: Player)
			if p.Character then
				onChar(p.Character)
			end
			table.insert(self.conns, p.CharacterAdded:Connect(onChar))
		end
		for _, p in Players:GetPlayers() do
			onPlayer(p)
		end
		table.insert(self.conns, Players.PlayerAdded:Connect(onPlayer))
	end

	local last = os.clock()
	table.insert(
		self.conns,
		RunService.Heartbeat:Connect(function()
			local now = os.clock()
			self:step(now - last)
			last = now
		end)
	)
end

--[=[
	Stops recording and returns the finished replay buffer.
	@within Recorder
]=]
function Recorder.stop(self: Recorder): buffer
	self.running = false
	for _, c in self.conns do
		c:Disconnect()
	end
	table.clear(self.conns)
	for _, e in self.entities do
		for _, c in e.conns do
			c:Disconnect()
		end
	end
	return self:finalize()
end

--[=[
	Assembles header, string table, keyframe index and op stream into a buffer.
	Safe to call while running to get a partial replay.
	@within Recorder
]=]
function Recorder.finalize(self: Recorder): buffer
	for _, e in self.entities do
		if not e.sub and not e.jointed then
			self:_flushSnapshot(e)
		end
	end
	local opBuf = self.ops:finish()
	local w = Serializer.newWriter(buffer.len(opBuf) + 65536)
	w:u32(Serializer.MAGIC)
	w:u8(Serializer.VERSION)
	w:u8(self.tickRate)
	w:u32(game.PlaceVersion)
	w:f64(self.startUnix)
	w:u32(self.tick)
	w:u16(#self.strings.list)
	w:u16(#self.keyframes)
	w:u32(buffer.len(opBuf))
	for _, s in self.strings.list do
		w:str16(s)
	end
	for _, k in self.keyframes do
		w:u32(k.tick)
		w:u32(k.offset)
	end
	w:buffer(opBuf)
	return w:finish()
end

function Recorder.isRunning(self: Recorder): boolean
	return self.running
end

--[=[
	Approximate size in bytes of the replay if finalized now.
	@within Recorder
]=]
function Recorder.byteCount(self: Recorder): number
	local total = 32 + self.ops.pos + #self.keyframes * 8
	for _, s in self.strings.list do
		total += 2 + #s
	end
	return total
end

function Recorder.elapsed(self: Recorder): number
	return self.tick / self.tickRate
end

return Recorder

--!strict
--[=[
	@class Player
	Decodes a replay buffer into a tick-indexed timeline and drives proxy
	instances with interpolation. Supports play, pause, seek and speed. Works on
	the client and inside Studio edit mode.
]=]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Serializer = require(script.Parent.Serializer)
local Snapshot = require(script.Parent.Snapshot)

local Op = Serializer.Op
local PT = Serializer.PropType
local Delta = Serializer.Delta

export type Options = {
	prototypes: Instance?,
	container: Instance?,
	autoStep: boolean?,
}

export type EventHandler = (any, number) -> ()
export type ChannelHandler = (Serializer.Reader, number) -> ()

type XformSample = { tick: number, pos: Vector3?, rot: CFrame? }
type DecodeState = { pos: Vector3, yaw: number?, rot: CFrame? }
type PropChange = { name: string, value: any }
type AnimRecord = { tick: number, kind: string, handle: number, animId: string?, fade: number?, speed: number? }

export type Entity = {
	id: number,
	descriptor: string,
	parentId: number,
	spawnTick: number,
	despawnTick: number?,
	xforms: { XformSample },
	props: { [number]: { PropChange } },
	anims: { AnimRecord },
	proxy: Instance?,
	ownsProxy: boolean,
	building: boolean,
	snapshot: buffer?,
	tracks: { [number]: AnimationTrack },
	trackSpeeds: { [number]: number },
	animator: Animator?,
}

export type Header = {
	tickRate: number,
	placeVersion: number,
	startUnix: number,
	tickCount: number,
}

type Fields = {
	prototypes: Instance?,
	container: Instance,
	ownsContainer: boolean,
	eventHandlers: { [string]: { EventHandler } },
	channelHandlers: { [string]: { ChannelHandler } },
	entities: { [number]: Entity },
	order: { number },
	events: { { tick: number, name: string, payload: any } },
	customs: { { tick: number, channel: string, data: buffer } },
	header: Header,
	speed: number,
	loop: boolean,
	reverse: boolean,
	discrete: { [number]: boolean },
	playing: boolean,
	time: number,
	lastFiredTick: number,
	stepConn: RBXScriptConnection?,
	templates: { [string]: Instance },
}

local Player = {}
Player.__index = Player

export type Player = typeof(setmetatable({} :: Fields, Player))

--[=[
	Reads only the header of a replay buffer without decoding the op stream.
	@within Player
]=]
function Player.readHeader(blob: buffer): Header
	local r = Serializer.newReader(blob)
	assert(r:u32() == Serializer.MAGIC, "not a Flashback replay")
	assert(r:u8() == Serializer.VERSION, "unsupported replay version")
	return {
		tickRate = r:u8(),
		placeVersion = r:u32(),
		startUnix = r:f64(),
		tickCount = r:u32(),
	}
end

function Player.new(blob: buffer, opts: Options?): Player
	local o: Options = opts or {}
	local container = o.container
	local owns = container == nil
	if not container then
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackProxies"
		folder.Archivable = false
		folder.Parent = workspace
		container = folder
	end
	local fields: Fields = {
		prototypes = o.prototypes,
		container = container :: Instance,
		ownsContainer = owns,
		eventHandlers = {},
		channelHandlers = {},
		entities = {},
		order = {},
		events = {},
		customs = {},
		header = { tickRate = 0, placeVersion = 0, startUnix = 0, tickCount = 0 },
		speed = 1,
		loop = false,
		reverse = false,
		discrete = {},
		playing = false,
		time = 0,
		lastFiredTick = 0,
		stepConn = nil,
		templates = {},
	}
	local self = setmetatable(fields, Player)
	self:_decode(blob)
	for _, e in self.entities do
		if e.snapshot then
			Snapshot.prefetch(e.snapshot)
		end
	end
	if o.autoStep ~= false then
		self:_bindStep()
	end
	return self
end

function Player._decode(self: Player, blob: buffer)
	local r = Serializer.newReader(blob)
	assert(r:u32() == Serializer.MAGIC, "not a Flashback replay")
	assert(r:u8() == Serializer.VERSION, "unsupported replay version")
	local header = self.header
	header.tickRate = r:u8()
	header.placeVersion = r:u32()
	header.startUnix = r:f64()
	header.tickCount = r:u32()
	local stringCount, keyframeCount, opBytes = r:u16(), r:u16(), r:u32()

	local strings = table.create(stringCount) :: { string }
	for i = 1, stringCount do
		strings[i] = r:str16()
	end
	r.pos += keyframeCount * 8

	local entities = self.entities
	local discrete = self.discrete
	local decode: { [number]: DecodeState } = {}
	local tick = 0
	local opEnd = r.pos + opBytes
	while r.pos < opEnd do
		local op = r:u8()
		if op == Op.TICK then
			tick = r:u32()
		elseif op == Op.TICK_NEXT then
			tick += 1
		elseif op == Op.SPAWN then
			discrete[tick] = true
			local id = r:u16()
			entities[id] = {
				id = id,
				descriptor = strings[r:u16()],
				parentId = r:u16(),
				spawnTick = tick,
				despawnTick = nil,
				xforms = {},
				props = {},
				anims = {},
				proxy = nil,
				ownsProxy = true,
				building = false,
				snapshot = nil,
				tracks = {},
				trackSpeeds = {},
				animator = nil,
			}
			table.insert(self.order, id)
		elseif op == Op.DESPAWN then
			discrete[tick] = true
			local e = entities[r:u16()]
			if e then
				e.despawnTick = tick
			end
		elseif op == Op.XFORM then
			local id = r:u16()
			local e = entities[id]
			local mask = r:u8()
			local sample: XformSample = { tick = tick }
			local state: DecodeState = { pos = Vector3.zero, yaw = nil, rot = nil }
			if bit32.band(mask, 1) ~= 0 then
				sample.pos = Vector3.new(r:f32(), r:f32(), r:f32())
				state.pos = sample.pos :: Vector3
			end
			if bit32.band(mask, 2) ~= 0 then
				sample.rot = Serializer.readRotation(r)
				state.rot = sample.rot
			end
			if bit32.band(mask, 4) ~= 0 then
				local yaw = Serializer.dequantizeYaw(r:i16())
				state.yaw = yaw
				sample.rot = CFrame.Angles(0, yaw, 0)
			end
			decode[id] = state
			if e then
				table.insert(e.xforms, sample)
			end
		elseif op == Op.XFORM_D then
			local id = r:id()
			local e = entities[id]
			local mask = r:u8()
			local state: DecodeState = decode[id] or { pos = Vector3.zero, yaw = nil, rot = nil }
			decode[id] = state
			local sample: XformSample = { tick = tick }
			if bit32.band(mask, Delta.POS8) ~= 0 then
				state.pos = state.pos + Vector3.new(r:i8(), r:i8(), r:i8()) / Serializer.POS_Q
				sample.pos = state.pos
			elseif bit32.band(mask, Delta.POS16) ~= 0 then
				state.pos = state.pos + Vector3.new(r:i16(), r:i16(), r:i16()) / Serializer.POS_Q
				sample.pos = state.pos
			end
			if bit32.band(mask, Delta.YAW) ~= 0 then
				local yaw = Serializer.wrapAngle((state.yaw or 0) + r:i8() / Serializer.YAW_Q)
				state.yaw = yaw
				sample.rot = CFrame.Angles(0, yaw, 0)
			end
			if bit32.band(mask, Delta.ROT) ~= 0 then
				local rot = (state.rot or CFrame.identity) * Serializer.rotationFromDelta(r:i8(), r:i8(), r:i8())
				state.rot = rot
				sample.rot = rot
			end
			if e then
				table.insert(e.xforms, sample)
			end
		elseif op == Op.PROP then
			discrete[tick] = true
			local e = entities[r:u16()]
			local name, t = strings[r:u16()], r:u8()
			local v: any
			if t == PT.Bool then
				v = r:u8() == 1
			elseif t == PT.Number then
				v = r:f64()
			elseif t == PT.String or t == PT.Enum then
				v = strings[r:u16()]
			elseif t == PT.Color3 then
				v = Color3.fromRGB(r:u8(), r:u8(), r:u8())
			elseif t == PT.Vector3 then
				v = Vector3.new(r:f32(), r:f32(), r:f32())
			else
				error(`unknown prop type {t} at {r.pos - 1}`)
			end
			if e then
				local list = e.props[tick]
				if not list then
					list = {}
					e.props[tick] = list
				end
				table.insert(list, { name = name, value = v })
			end
		elseif op == Op.ANIM_PLAY then
			discrete[tick] = true
			local e = entities[r:u16()]
			local rec: AnimRecord = {
				tick = tick,
				kind = "play",
				animId = strings[r:u16()],
				handle = r:u8(),
				fade = r:u8() / 100,
				speed = r:i16() / 256,
			}
			if e then
				table.insert(e.anims, rec)
			end
		elseif op == Op.ANIM_STOP then
			discrete[tick] = true
			local e = entities[r:u16()]
			local rec: AnimRecord = { tick = tick, kind = "stop", handle = r:u8(), fade = r:u8() / 100 }
			if e then
				table.insert(e.anims, rec)
			end
		elseif op == Op.ANIM_SPEED then
			discrete[tick] = true
			local e = entities[r:u16()]
			local rec: AnimRecord = { tick = tick, kind = "speed", handle = r:u8(), speed = r:i16() / 256 }
			if e then
				table.insert(e.anims, rec)
			end
		elseif op == Op.SNAPSHOT then
			local e = entities[r:u16()]
			local len = r:u32()
			local data = r:slice(len)
			if e then
				e.snapshot = data
			end
		elseif op == Op.EVENT then
			discrete[tick] = true
			local name, payload = strings[r:u16()], strings[r:u16()]
			table.insert(self.events, { tick = tick, name = name, payload = HttpService:JSONDecode(payload) })
		elseif op == Op.CUSTOM then
			discrete[tick] = true
			local channel, len = strings[r:u16()], r:u16()
			table.insert(self.customs, { tick = tick, channel = channel, data = r:slice(len) })
		else
			error(`unknown op {op} at {r.pos - 1}`)
		end
	end
end

function Player.onEvent(self: Player, name: string, fn: EventHandler)
	local list = self.eventHandlers[name]
	if not list then
		list = {}
		self.eventHandlers[name] = list
	end
	table.insert(list, fn)
end

function Player.onChannel(self: Player, name: string, fn: ChannelHandler)
	local list = self.channelHandlers[name]
	if not list then
		list = {}
		self.channelHandlers[name] = list
	end
	table.insert(list, fn)
end

-- Makes a proxy inert. Rigs with a Humanoid keep their limbs unanchored so
-- joints and animations still move them relative to the anchored root.
local function stripPhysics(inst: Instance)
	inst.Archivable = false
	local humanoid = inst:FindFirstChildWhichIsA("Humanoid")
	local rig = humanoid ~= nil and inst:IsA("Model")
	local root = if rig then (inst :: Model).PrimaryPart or inst:FindFirstChild("HumanoidRootPart") else nil
	for _, d in inst:GetDescendants() do
		d.Archivable = false
		if d:IsA("BasePart") then
			d.Anchored = not rig or d == root
			d.Massless = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("BaseScript") then
			d:Destroy()
		end
	end
	if inst:IsA("BasePart") then
		inst.Anchored = true
		inst.CanCollide = false
	end
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.EvaluateStateMachine = false
		humanoid.RequiresNeck = false
		humanoid.BreakJointsOnDeath = false
		if not humanoid:FindFirstChildWhichIsA("Animator") then
			Instance.new("Animator").Parent = humanoid
		end
	end
end

--[=[
	Fetches a character model once per user and reuses clones afterwards, so
	rewinding never waits on the network or spawns duplicates.
	@within Player
]=]
function Player._characterTemplate(self: Player, userId: number): Instance?
	local key = `char:{userId}`
	local cached = self.templates[key]
	if cached then
		return cached
	end
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromUserId(userId)
	end)
	if ok and model then
		model.Archivable = false
		self.templates[key] = model
		return model
	end
	return nil
end

function Player._buildProxy(self: Player, e: Entity): Instance
	local kind, arg = e.descriptor:match("^(%w+):(.*)$")
	local parentEnt = if e.parentId ~= 0 then self.entities[e.parentId] else nil
	local inst: Instance?
	e.ownsProxy = true
	if kind == "sub" then
		local parentProxy = if parentEnt then parentEnt.proxy else nil
		local existing = if parentProxy
			then Snapshot.resolve(parentProxy, arg :: string) or parentProxy:FindFirstChild(arg :: string, true)
			else nil
		if existing and existing:IsA("BasePart") then
			e.ownsProxy = false
			e.animator = nil
			for _, d in (parentProxy :: Instance):GetDescendants() do
				if d:IsA("JointInstance") and (d.Part0 == existing or d.Part1 == existing) then
					d:Destroy()
				end
			end
			existing.Anchored = true
			return existing
		end
		local ph = Instance.new("Part")
		ph.Size = Vector3.one
		ph.Color = Color3.fromRGB(160, 160, 170)
		inst = ph
	elseif kind == "char" and not e.snapshot then
		local template = self:_characterTemplate(tonumber(arg) :: number)
		if template then
			inst = template:Clone()
		end
	elseif kind == "model" and self.prototypes then
		local proto = (self.prototypes :: Instance):FindFirstChild(arg :: string, true)
		if proto then
			inst = proto:Clone()
		end
	end
	if not inst and e.snapshot then
		inst = Snapshot.build(e.snapshot)
	end
	if kind == "part" then
		local p: Instance = inst or Instance.new("Part")
		if p:IsA("Part") then
			for _, item in Enum.PartType:GetEnumItems() do
				if item.Name == arg then
					p.Shape = item
				end
			end
		end
		inst = p
	end
	if not inst then
		local ph = Instance.new("Part")
		ph.Size = Vector3.one * 2
		ph.Color = Color3.new(1, 0, 1)
		inst = ph
	end
	local built = inst :: Instance
	stripPhysics(built)
	built.Name = `E{e.id}`
	built.Parent = if parentEnt and parentEnt.proxy then parentEnt.proxy else self.container
	e.animator = built:FindFirstChildWhichIsA("Animator", true)
	return built
end

local function findSample(samples: { XformSample }, t: number): number
	local lo, hi, ans = 1, #samples, 0
	while lo <= hi do
		local mid = (lo + hi) // 2
		if samples[mid].tick <= t then
			ans = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	return ans
end

local function resolveAt(samples: { XformSample }, i: number): CFrame
	local pos: Vector3?, rot: CFrame?
	for j = i, 1, -1 do
		local s = samples[j]
		pos = pos or s.pos
		rot = rot or s.rot
		if pos and rot then
			break
		end
	end
	return CFrame.new(pos or Vector3.zero) * (rot or CFrame.identity)
end

--[=[
	Returns the interpolated CFrame of an entity at a fractional tick, or nil
	before its first sample.
	@within Player
]=]
function Player.cframeAt(_self: Player, e: Entity, t: number): CFrame?
	local i = findSample(e.xforms, t)
	if i == 0 then
		return nil
	end
	local a = resolveAt(e.xforms, i)
	local nxt = e.xforms[i + 1]
	if not nxt then
		return a
	end
	local b = resolveAt(e.xforms, i + 1)
	local alpha = (t - e.xforms[i].tick) / (nxt.tick - e.xforms[i].tick)
	return a:Lerp(b, math.clamp(alpha, 0, 1))
end

local function applyProp(inst: Instance, name: string, v: any)
	local target: any = inst
	local prop = name
	if name:find("/", 1, true) then
		local segments = name:split("/")
		prop = table.remove(segments) :: string
		target = Snapshot.resolve(inst, table.concat(segments, "/"))
		if not target then
			return
		end
	end
	pcall(function()
		if prop:sub(1, 1) == "@" then
			target:SetAttribute(prop:sub(2), v)
			return
		elseif prop == "Scale" and target:IsA("Model") then
			target:ScaleTo(v)
			return
		end
		local cur = target[prop]
		if typeof(cur) == "EnumItem" and typeof(v) == "string" then
			local enumType: any = cur.EnumType
			target[prop] = enumType[v]
		else
			target[prop] = v
		end
	end)
end

function Player._applyDiscrete(self: Player, e: Entity, fromTick: number, toTick: number)
	local proxy = e.proxy
	if not proxy then
		return
	end
	for t = fromTick + 1, toTick do
		local list = e.props[t]
		if list then
			for _, p in list do
				applyProp(proxy, p.name, p.value)
			end
		end
	end
	local animator = e.animator
	if not animator then
		return
	end
	for _, a in e.anims do
		if a.tick > fromTick and a.tick <= toTick then
			if a.kind == "play" then
				local anim = Instance.new("Animation")
				anim.AnimationId = a.animId :: string
				local ok, track = pcall(animator.LoadAnimation, animator, anim)
				if ok then
					local speed = a.speed or 1
					track:Play(a.fade, 1, self:_trackSpeed(speed))
					local elapsed = (toTick - a.tick) / self.header.tickRate * speed
					if track.Length > 0 then
						track.TimePosition = if track.Looped
							then elapsed % track.Length
							else math.min(elapsed, track.Length)
					end
					e.tracks[a.handle] = track
					e.trackSpeeds[a.handle] = speed
				end
			elseif a.kind == "stop" and e.tracks[a.handle] then
				e.tracks[a.handle]:Stop(a.fade)
				e.tracks[a.handle] = nil
				e.trackSpeeds[a.handle] = nil
			elseif a.kind == "speed" and e.tracks[a.handle] then
				local speed = a.speed or 1
				e.trackSpeeds[a.handle] = speed
				e.tracks[a.handle]:AdjustSpeed(self:_trackSpeed(speed))
			end
		end
	end
end

--[=[
	Speed an animation track should run at: its recorded speed scaled by the
	playhead speed, and zero while paused.
	@within Player
]=]
function Player._trackSpeed(self: Player, recorded: number): number
	return if self.playing then recorded * self.speed * (if self.reverse then -1 else 1) else 0
end

function Player._syncTrackSpeeds(self: Player)
	for _, e in self.entities do
		for handle, track in e.tracks do
			track:AdjustSpeed(self:_trackSpeed(e.trackSpeeds[handle] or 1))
		end
	end
end

function Player._destroyProxy(_self: Player, e: Entity)
	for _, tr in e.tracks do
		tr:Stop(0)
	end
	table.clear(e.tracks)
	table.clear(e.trackSpeeds)
	local proxy = e.proxy
	if proxy and e.ownsProxy then
		proxy:Destroy()
	end
	e.proxy = nil
	e.animator = nil
end

function Player._render(self: Player, t: number)
	for _, id in self.order do
		local e = self.entities[id]
		local alive = e.spawnTick <= t and (e.despawnTick == nil or t < e.despawnTick)
		if alive and not e.proxy and not e.building then
			e.building = true
			local proxy = self:_buildProxy(e)
			e.building = false
			local stillAlive = e.spawnTick <= self.time and (e.despawnTick == nil or self.time < e.despawnTick)
			if stillAlive and not e.proxy then
				e.proxy = proxy
				self:_applyDiscrete(e, e.spawnTick - 1, math.floor(self.time))
			elseif e.ownsProxy then
				proxy:Destroy()
			end
		elseif not alive and e.proxy then
			self:_destroyProxy(e)
		end
		local proxy = e.proxy
		if proxy then
			local cf = self:cframeAt(e, t)
			if cf then
				if proxy:IsA("Model") then
					proxy:PivotTo(cf)
				elseif proxy:IsA("BasePart") then
					proxy.CFrame = cf
				end
			end
		end
	end
end

function Player._fireDiscrete(self: Player, fromTick: number, toTick: number)
	if toTick <= fromTick then
		return
	end
	for _, e in self.entities do
		self:_applyDiscrete(e, fromTick, toTick)
	end
	for _, ev in self.events do
		if ev.tick > fromTick and ev.tick <= toTick then
			local list = self.eventHandlers[ev.name]
			if list then
				for _, fn in list do
					fn(ev.payload, ev.tick)
				end
			end
		end
	end
	for _, c in self.customs do
		if c.tick > fromTick and c.tick <= toTick then
			local list = self.channelHandlers[c.channel]
			if list then
				for _, fn in list do
					fn(Serializer.newReader(c.data), c.tick)
				end
			end
		end
	end
end

--[=[
	Advances playback by dt seconds and renders. Called automatically each
	frame unless autoStep is false. In Studio edit mode animation tracks do
	not advance on their own, so animators are stepped here. In reverse the
	playhead runs backwards; transforms interpolate either way, and proxies
	are rebuilt from spawn only when the playhead crosses a tick that
	carries discrete state.
	@within Player
]=]
function Player.step(self: Player, dt: number)
	local tickCount = self.header.tickCount
	local first = math.min(1, tickCount)
	if self.playing and self.reverse then
		self.time = math.max(self.time - dt * self.header.tickRate * self.speed, first)
		local nowTick = math.floor(self.time)
		if nowTick < self.lastFiredTick then
			local crossed = false
			for t = nowTick + 1, self.lastFiredTick do
				if self.discrete[t] then
					crossed = true
					break
				end
			end
			if crossed then
				self:_rewind(self.time)
			end
			self.lastFiredTick = nowTick
		end
		if self.time <= first then
			if self.loop then
				self:seek(tickCount)
			else
				self.playing = false
				self:_syncTrackSpeeds()
			end
		end
	elseif self.playing then
		self.time = math.min(self.time + dt * self.header.tickRate * self.speed, tickCount)
		if self.time >= tickCount then
			if self.loop then
				self:seek(1)
			else
				self.playing = false
				self:_syncTrackSpeeds()
			end
		end
	end
	self:_render(self.time)
	if self.playing and not RunService:IsRunning() then
		for _, e in self.entities do
			local animator = e.animator
			if animator then
				pcall(function()
					animator:StepAnimations(dt)
				end)
			end
		end
	end
	local nowTick = math.floor(self.time)
	if nowTick > self.lastFiredTick then
		self:_fireDiscrete(self.lastFiredTick, nowTick)
		self.lastFiredTick = nowTick
	end
end

function Player._bindStep(self: Player)
	local signal: RBXScriptSignal = if RunService:IsClient() then RunService.RenderStepped else RunService.Heartbeat
	self.stepConn = signal:Connect(function(dt: number)
		self:step(dt)
	end)
end

function Player.play(self: Player)
	if self.reverse then
		if self.time <= math.min(1, self.header.tickCount) then
			self:seek(self.header.tickCount)
		end
	elseif self.time >= self.header.tickCount then
		self:seek(1)
	end
	self.playing = true
	self:_syncTrackSpeeds()
end

--[=[
	When on, playing runs the playhead backwards from its current position.
	@within Player
]=]
function Player.setReverse(self: Player, reverse: boolean)
	self.reverse = reverse
	self:_syncTrackSpeeds()
end

function Player.isReversed(self: Player): boolean
	return self.reverse
end

function Player.pause(self: Player)
	self.playing = false
	self:_syncTrackSpeeds()
end

function Player.isPlaying(self: Player): boolean
	return self.playing
end

function Player.setSpeed(self: Player, speed: number)
	self.speed = speed
	self:_syncTrackSpeeds()
end

--[=[
	When on, reaching the end restarts from the first tick instead of pausing.
	@within Player
]=]
function Player.setLoop(self: Player, loop: boolean)
	self.loop = loop
end

--[=[
	Jumps to a tick. Seeking backwards rebuilds proxies so discrete state is
	replayed from spawn. Seeking forwards applies entity state without
	firing event or channel handlers. Ticks start at 1, so seeking to 0 shows
	the first recorded state rather than empty proxies.
	@within Player
]=]
function Player.seek(self: Player, tick: number)
	tick = math.clamp(tick, math.min(1, self.header.tickCount), self.header.tickCount)
	local target = math.floor(tick)
	if tick < self.time then
		self:_rewind(tick)
		return
	else
		for _, e in self.entities do
			self:_applyDiscrete(e, self.lastFiredTick, target)
		end
	end
	self.time = tick
	self.lastFiredTick = target
	self:_render(tick)
end

--[=[
	Rebuilds every proxy so discrete state is replayed from spawn up to
	`tick`.
	@within Player
]=]
function Player._rewind(self: Player, tick: number)
	for i = #self.order, 1, -1 do
		self:_destroyProxy(self.entities[self.order[i]])
	end
	self.time = tick
	self.lastFiredTick = math.floor(tick)
	self:_render(tick)
end

function Player.seekSeconds(self: Player, s: number)
	self:seek(s * self.header.tickRate)
end

function Player.currentTick(self: Player): number
	return self.time
end

function Player.currentSeconds(self: Player): number
	return self.time / self.header.tickRate
end

function Player.tickCount(self: Player): number
	return self.header.tickCount
end

function Player.duration(self: Player): number
	return self.header.tickCount / self.header.tickRate
end

export type Link = { key: string, kind: "model" | "union", resolved: boolean }

--[=[
	Everything in this replay that can be linked to an instance in Studio:
	recorded models (link a prefab to clone it instead of the snapshot) and
	the unions inside them. Link with `Snapshot.link` and reload.
	@within Player
]=]
function Player.links(self: Player): { Link }
	local seen: { [string]: boolean } = {}
	local out: { Link } = {}
	local function add(key: string, kind: "model" | "union", resolved: boolean)
		if not seen[key] then
			seen[key] = true
			table.insert(out, { key = key, kind = kind, resolved = resolved })
		end
	end
	for _, e in self.entities do
		if e.snapshot then
			local keys = Snapshot.keys(e.snapshot)
			if keys.isModel then
				add(keys.source, "model", Snapshot.links[keys.source] ~= nil)
			end
			for _, key in keys.unions do
				add(key, "union", Snapshot.resolveUnion(key) ~= nil)
			end
		end
	end
	table.sort(out, function(a, b)
		return if a.kind ~= b.kind then a.kind < b.kind else a.key < b.key
	end)
	return out
end

function Player.getEntities(self: Player): { [number]: Entity }
	return self.entities
end

function Player.destroy(self: Player)
	local conn = self.stepConn
	if conn then
		conn:Disconnect()
		self.stepConn = nil
	end
	self.playing = false
	for i = #self.order, 1, -1 do
		self:_destroyProxy(self.entities[self.order[i]])
	end
	for _, template in self.templates do
		template:Destroy()
	end
	table.clear(self.templates)
	if self.ownsContainer then
		self.container:Destroy()
	end
end

return Player

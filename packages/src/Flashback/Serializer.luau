--!strict
--[=[
	@class Serializer
	Growable little-endian buffer writer and reader, rotation quantization and
	string interning. Shared by the Recorder and the Player.
]=]

local Serializer = {}

Serializer.MAGIC = 0x594C5052
Serializer.VERSION = 3

Serializer.Op = {
	TICK = 0,
	SPAWN = 1,
	DESPAWN = 2,
	XFORM = 3,
	PROP = 4,
	ANIM_PLAY = 5,
	ANIM_STOP = 6,
	ANIM_SPEED = 7,
	EVENT = 8,
	CUSTOM = 9,
	TICK_NEXT = 10,
	XFORM_D = 11,
	SNAPSHOT = 14,
}

Serializer.POS_Q = 32
Serializer.YAW_Q = 64
Serializer.ROT_Q = 128

-- XFORM_D mask bits: which deltas follow the entity id.
Serializer.Delta = {
	POS8 = 1,
	POS16 = 2,
	YAW = 4,
	ROT = 8,
}

Serializer.PropType = {
	Bool = 0,
	Number = 1,
	String = 2,
	Color3 = 3,
	Vector3 = 4,
	Enum = 5,
}

local Writer = {}
Writer.__index = Writer

type WriterFields = { buf: buffer, pos: number }
export type Writer = typeof(setmetatable({} :: WriterFields, Writer))

--[=[
	Creates a writer with an initial capacity. The buffer doubles as needed.
	@within Serializer
]=]
function Serializer.newWriter(initial: number?): Writer
	return setmetatable({ buf = buffer.create(initial or 65536), pos = 0 }, Writer)
end

local function ensure(w: Writer, n: number)
	local need = w.pos + n
	local len = buffer.len(w.buf)
	if need > len then
		local newLen = math.max(len, 16)
		repeat
			newLen *= 2
		until newLen >= need
		local nb = buffer.create(newLen)
		buffer.copy(nb, 0, w.buf, 0, w.pos)
		w.buf = nb
	end
end

function Writer.u8(self: Writer, v: number)
	ensure(self, 1)
	buffer.writeu8(self.buf, self.pos, v)
	self.pos += 1
end

function Writer.i8(self: Writer, v: number)
	ensure(self, 1)
	buffer.writei8(self.buf, self.pos, v)
	self.pos += 1
end

function Writer.u16(self: Writer, v: number)
	ensure(self, 2)
	buffer.writeu16(self.buf, self.pos, v)
	self.pos += 2
end

function Writer.i16(self: Writer, v: number)
	ensure(self, 2)
	buffer.writei16(self.buf, self.pos, v)
	self.pos += 2
end

function Writer.u32(self: Writer, v: number)
	ensure(self, 4)
	buffer.writeu32(self.buf, self.pos, v)
	self.pos += 4
end

function Writer.f32(self: Writer, v: number)
	ensure(self, 4)
	buffer.writef32(self.buf, self.pos, v)
	self.pos += 4
end

function Writer.f64(self: Writer, v: number)
	ensure(self, 8)
	buffer.writef64(self.buf, self.pos, v)
	self.pos += 8
end

function Writer.bytes(self: Writer, s: string)
	ensure(self, #s)
	buffer.writestring(self.buf, self.pos, s)
	self.pos += #s
end

function Writer.buffer(self: Writer, b: buffer)
	local n = buffer.len(b)
	ensure(self, n)
	buffer.copy(self.buf, self.pos, b, 0, n)
	self.pos += n
end

-- Entity id: one byte below 255, otherwise 0xFF followed by u16.
function Writer.id(self: Writer, v: number)
	if v < 255 then
		self:u8(v)
	else
		self:u8(255)
		self:u16(v)
	end
end

function Writer.str16(self: Writer, s: string)
	self:u16(#s)
	self:bytes(s)
end

-- Returns an exact-length copy of everything written so far.
function Writer.finish(self: Writer): buffer
	local out = buffer.create(self.pos)
	buffer.copy(out, 0, self.buf, 0, self.pos)
	return out
end

local Reader = {}
Reader.__index = Reader

type ReaderFields = { buf: buffer, pos: number }
export type Reader = typeof(setmetatable({} :: ReaderFields, Reader))

function Serializer.newReader(buf: buffer, pos: number?): Reader
	return setmetatable({ buf = buf, pos = pos or 0 }, Reader)
end

function Reader.u8(self: Reader): number
	local v = buffer.readu8(self.buf, self.pos)
	self.pos += 1
	return v
end

function Reader.i8(self: Reader): number
	local v = buffer.readi8(self.buf, self.pos)
	self.pos += 1
	return v
end

function Reader.u16(self: Reader): number
	local v = buffer.readu16(self.buf, self.pos)
	self.pos += 2
	return v
end

function Reader.i16(self: Reader): number
	local v = buffer.readi16(self.buf, self.pos)
	self.pos += 2
	return v
end

function Reader.u32(self: Reader): number
	local v = buffer.readu32(self.buf, self.pos)
	self.pos += 4
	return v
end

function Reader.f32(self: Reader): number
	local v = buffer.readf32(self.buf, self.pos)
	self.pos += 4
	return v
end

function Reader.f64(self: Reader): number
	local v = buffer.readf64(self.buf, self.pos)
	self.pos += 8
	return v
end

function Reader.bytes(self: Reader, n: number): string
	local s = buffer.readstring(self.buf, self.pos, n)
	self.pos += n
	return s
end

function Reader.slice(self: Reader, n: number): buffer
	local out = buffer.create(n)
	buffer.copy(out, 0, self.buf, self.pos, n)
	self.pos += n
	return out
end

function Reader.id(self: Reader): number
	local v = self:u8()
	return if v == 255 then self:u16() else v
end

function Reader.str16(self: Reader): string
	return self:bytes(self:u16())
end

function Reader.eof(self: Reader): boolean
	return self.pos >= buffer.len(self.buf)
end

local Q = 32767 / math.pi

--[=[
	Writes the rotation of a CFrame as an axis-angle vector quantized to 3 x i16.
	@within Serializer
]=]
function Serializer.writeRotation(w: Writer, cf: CFrame)
	local axis, angle = cf:ToAxisAngle()
	local v = axis * angle
	w:i16(math.clamp(math.round(v.X * Q), -32767, 32767))
	w:i16(math.clamp(math.round(v.Y * Q), -32767, 32767))
	w:i16(math.clamp(math.round(v.Z * Q), -32767, 32767))
end

function Serializer.readRotation(r: Reader): CFrame
	local v = Vector3.new(r:i16() / Q, r:i16() / Q, r:i16() / Q)
	local angle = v.Magnitude
	if angle < 1e-6 then
		return CFrame.identity
	end
	return CFrame.fromAxisAngle(v / angle, angle)
end

--[=[
	Rotation delta from three i8 axis-angle components in 1/ROT_Q radians.
	@within Serializer
]=]
function Serializer.rotationFromDelta(x: number, y: number, z: number): CFrame
	local v = Vector3.new(x, y, z) / Serializer.ROT_Q
	local angle = v.Magnitude
	if angle < 1e-6 then
		return CFrame.identity
	end
	return CFrame.fromAxisAngle(v / angle, angle)
end

local YAW_SCALE = 32767 / math.pi

--[=[
	True when the CFrame is a pure rotation about the world Y axis, the common
	case for characters and vehicles.
	@within Serializer
]=]
function Serializer.isYawOnly(cf: CFrame): boolean
	return cf.UpVector:Dot(Vector3.yAxis) > 0.99995
end

function Serializer.yawOf(cf: CFrame): number
	local look = cf.LookVector
	return math.atan2(-look.X, -look.Z)
end

function Serializer.wrapAngle(a: number): number
	return (a + math.pi) % (2 * math.pi) - math.pi
end

function Serializer.quantizeYaw(yaw: number): number
	return math.clamp(math.round(Serializer.wrapAngle(yaw) * YAW_SCALE), -32767, 32767)
end

function Serializer.dequantizeYaw(q: number): number
	return q / YAW_SCALE
end

function Serializer.yawCFrame(pos: Vector3, yaw: number): CFrame
	return CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX: { [number]: number } = {}
for i = 1, 64 do
	B64_INDEX[string.byte(B64, i)] = i - 1
end

--[=[
	Base64 encodes a buffer so it can live inside JSON such as plugin settings.
	@within Serializer
]=]
function Serializer.toBase64(data: buffer): string
	local n = buffer.len(data)
	local out = table.create(math.ceil(n / 3))
	for i = 0, n - 1, 3 do
		local a = buffer.readu8(data, i)
		local b = if i + 1 < n then buffer.readu8(data, i + 1) else 0
		local c = if i + 2 < n then buffer.readu8(data, i + 2) else 0
		local triple = a * 65536 + b * 256 + c
		local c1 = string.sub(B64, (triple // 262144) % 64 + 1, (triple // 262144) % 64 + 1)
		local c2 = string.sub(B64, (triple // 4096) % 64 + 1, (triple // 4096) % 64 + 1)
		local c3 = if i + 1 < n then string.sub(B64, (triple // 64) % 64 + 1, (triple // 64) % 64 + 1) else "="
		local c4 = if i + 2 < n then string.sub(B64, triple % 64 + 1, triple % 64 + 1) else "="
		table.insert(out, c1 .. c2 .. c3 .. c4)
	end
	return table.concat(out)
end

function Serializer.fromBase64(text: string): buffer
	local clean = text:gsub("[^%w%+/]", "")
	local n = #clean
	local out = buffer.create(math.ceil(n / 4) * 3)
	local pos = 0
	for i = 1, n, 4 do
		local v = 0
		local count = 0
		for j = 0, 3 do
			local ch = string.byte(clean, i + j)
			local idx = if ch then B64_INDEX[ch] else nil
			v = v * 64 + (idx or 0)
			if idx then
				count += 1
			end
		end
		local bytesHere = math.max(0, count - 1)
		if bytesHere >= 1 then
			buffer.writeu8(out, pos, (v // 65536) % 256)
		end
		if bytesHere >= 2 then
			buffer.writeu8(out, pos + 1, (v // 256) % 256)
		end
		if bytesHere >= 3 then
			buffer.writeu8(out, pos + 2, v % 256)
		end
		pos += bytesHere
	end
	local exact = buffer.create(pos)
	buffer.copy(exact, 0, out, 0, pos)
	return exact
end

export type StringTable = {
	list: { string },
	index: { [string]: number },
	intern: (string) -> number,
}

--[=[
	Interns strings to 1-based ids so the op stream only carries u16 references.
	@within Serializer
]=]
function Serializer.newStringTable(): StringTable
	local list: { string } = {}
	local index: { [string]: number } = {}
	local t: StringTable = {
		list = list,
		index = index,
		intern = function(s: string): number
			local existing = index[s]
			if existing then
				return existing
			end
			local id = #list + 1
			list[id] = s
			index[s] = id
			return id
		end,
	}
	return t
end

return Serializer

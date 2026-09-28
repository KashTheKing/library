--!strict
local Assert = require(script.Parent.Assert)
local Serializer = require(script.Parent.Parent.Serializer)

return {
	roundTripsScalars = function(t: Assert.T)
		local w = Serializer.newWriter(4)
		w:u8(255)
		w:u16(65535)
		w:i16(-12345)
		w:u32(4000000000)
		w:f32(1.5)
		w:f64(math.pi)
		w:str16("hello")
		local r = Serializer.newReader(w:finish())
		t.eq(r:u8(), 255)
		t.eq(r:u16(), 65535)
		t.eq(r:i16(), -12345)
		t.eq(r:u32(), 4000000000)
		t.eq(r:f32(), 1.5)
		t.eq(r:f64(), math.pi)
		t.eq(r:str16(), "hello")
		t.ok(r:eof())
	end,

	growsPastInitialCapacity = function(t: Assert.T)
		local w = Serializer.newWriter(2)
		for i = 1, 1000 do
			w:u32(i)
		end
		local r = Serializer.newReader(w:finish())
		for i = 1, 1000 do
			t.eq(r:u32(), i)
		end
	end,

	copiesBuffers = function(t: Assert.T)
		local inner = Serializer.newWriter(8)
		inner:u16(7)
		inner:u16(9)
		local w = Serializer.newWriter(8)
		w:buffer(inner:finish())
		local r = Serializer.newReader(w:finish())
		local slice = r:slice(4)
		local r2 = Serializer.newReader(slice)
		t.eq(r2:u16(), 7)
		t.eq(r2:u16(), 9)
	end,

	quantizesRotationWithinHalfDegree = function(t: Assert.T)
		local cases = {
			CFrame.identity,
			CFrame.Angles(1, 0, 0),
			CFrame.Angles(0, 2, 0),
			CFrame.Angles(0.3, -1.2, 2.9),
			CFrame.Angles(math.pi, 0, 0),
		}
		for _, cf in cases do
			local w = Serializer.newWriter(6)
			Serializer.writeRotation(w, cf)
			t.eq(w.pos, 6)
			local out = Serializer.readRotation(Serializer.newReader(w:finish()))
			local _, err = (cf.Rotation:Inverse() * out):ToAxisAngle()
			t.ok(err < math.rad(0.5), `rotation error {math.deg(err)} deg`)
		end
	end,

	base64RoundTrips = function(t: Assert.T)
		for _, len in { 0, 1, 2, 3, 4, 5, 31, 300 } do
			local src = buffer.create(len)
			for i = 0, len - 1 do
				buffer.writeu8(src, i, (i * 37 + 11) % 256)
			end
			local text = Serializer.toBase64(src)
			t.eq(#text % 4, 0, `padded length for {len}`)
			local back = Serializer.fromBase64(text)
			t.eq(buffer.len(back), len, `length for {len}`)
			t.eq(buffer.tostring(back), buffer.tostring(src), `bytes for {len}`)
		end
		t.eq(Serializer.toBase64(buffer.fromstring("Man")), "TWFu")
		t.eq(Serializer.toBase64(buffer.fromstring("Ma")), "TWE=")
	end,

	internsStrings = function(t: Assert.T)
		local st = Serializer.newStringTable()
		t.eq(st.intern("a"), 1)
		t.eq(st.intern("b"), 2)
		t.eq(st.intern("a"), 1)
		t.eq(#st.list, 2)
	end,
}

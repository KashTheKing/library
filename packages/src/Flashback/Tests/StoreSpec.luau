--!strict
local Assert = require(script.Parent.Assert)
local Recorder = require(script.Parent.Parent.Recorder)
local Store = require(script.Parent.Parent.Store)

local STORE = "FlashbackTests"

local function available(): boolean
	return (pcall(function()
		game:GetService("DataStoreService"):GetDataStore(STORE):GetAsync("probe")
	end))
end

return {
	savesLoadsListsAndRemoves = function(t: Assert.T)
		if not available() then
			warn("Store.spec skipped: DataStore access unavailable (enable Studio API access)")
			return
		end
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		for _ = 1, 5 do
			rec:snapshot()
		end
		local blob = rec:stop()
		local key = `test_{os.time()}_{math.random(1, 1e6)}`

		local meta = Store.save(key, blob, STORE)
		t.eq(meta.chunks, 1)
		t.eq(meta.bytes, buffer.len(blob))
		t.eq(meta.tickCount, 5)
		t.eq(meta.tickRate, 10)
		t.ok(table.find(Store.list(STORE), key), "listed")

		local loaded = assert(Store.load(key, STORE), "loaded")
		t.eq(buffer.len(loaded), buffer.len(blob))
		t.eq(buffer.tostring(loaded), buffer.tostring(blob))

		Store.remove(key, STORE)
		t.eq(Store.load(key, STORE), nil)
		t.eq(table.find(Store.list(STORE), key), nil, "unlisted")
	end,
}

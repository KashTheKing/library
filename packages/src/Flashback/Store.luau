--!strict
--[=[
	@class Store
	Saves and loads replay buffers through DataStoreService, splitting large
	replays across multiple keys so each stays under the per-key limit.
]=]

local DataStoreService = game:GetService("DataStoreService")

local Serializer = require(script.Parent.Serializer)

local CHUNK_BYTES = 3 * 1024 * 1024

export type Meta = {
	chunks: number,
	bytes: number,
	tickRate: number,
	tickCount: number,
	placeVersion: number,
	startUnix: number,
	savedAt: number,
}

local Store = {}

Store.STORE_NAME = "Flashback"
Store.INDEX_KEY = "index"

local function dataStore(name: string?): DataStore
	return DataStoreService:GetDataStore(name or Store.STORE_NAME)
end

--[=[
	Saves a replay under a key and records it in the index. Yields.
	@within Store
]=]
function Store.save(key: string, blob: buffer, storeName: string?): Meta
	local ds = dataStore(storeName)
	local total = buffer.len(blob)
	local chunks = math.max(1, math.ceil(total / CHUNK_BYTES))
	for i = 1, chunks do
		local offset = (i - 1) * CHUNK_BYTES
		local n = math.min(CHUNK_BYTES, total - offset)
		local part = buffer.create(n)
		buffer.copy(part, 0, blob, offset, n)
		ds:SetAsync(`{key}/{i}`, part)
	end
	local r = Serializer.newReader(blob)
	r.pos = 5
	local meta: Meta = {
		chunks = chunks,
		bytes = total,
		tickRate = r:u8(),
		placeVersion = r:u32(),
		startUnix = r:f64(),
		tickCount = r:u32(),
		savedAt = os.time(),
	}
	ds:SetAsync(`{key}/meta`, meta)
	ds:UpdateAsync(Store.INDEX_KEY, function(index: { string }?): { string }
		local list = index or {}
		if not table.find(list, key) then
			table.insert(list, key)
		end
		return list
	end)
	return meta
end

--[=[
	Loads a replay by key, or nil if it does not exist. Yields.
	@within Store
]=]
function Store.load(key: string, storeName: string?): buffer?
	local ds = dataStore(storeName)
	local meta = ds:GetAsync(`{key}/meta`) :: Meta?
	if not meta then
		return nil
	end
	local out = buffer.create(meta.bytes)
	local offset = 0
	for i = 1, meta.chunks do
		local part = ds:GetAsync(`{key}/{i}`) :: buffer
		local n = buffer.len(part)
		buffer.copy(out, offset, part, 0, n)
		offset += n
	end
	return out
end

function Store.meta(key: string, storeName: string?): Meta?
	return dataStore(storeName):GetAsync(`{key}/meta`) :: Meta?
end

function Store.list(storeName: string?): { string }
	return (dataStore(storeName):GetAsync(Store.INDEX_KEY) :: { string }?) or {}
end

function Store.remove(key: string, storeName: string?)
	local ds = dataStore(storeName)
	local meta = ds:GetAsync(`{key}/meta`) :: Meta?
	if meta then
		for i = 1, meta.chunks do
			ds:RemoveAsync(`{key}/{i}`)
		end
		ds:RemoveAsync(`{key}/meta`)
	end
	ds:UpdateAsync(Store.INDEX_KEY, function(index: { string }?): { string }
		local list = index or {}
		local i = table.find(list, key)
		if i then
			table.remove(list, i)
		end
		return list
	end)
end

return Store

--!strict


-- Requires
local Signal = require(script.Signal)
local Task = require(script.Task)
local Types = require(script.Types)


-- Types
export type Packet<A... = (), B... = ()> = {
	Type:					"Packet",
	Id:						number,
	Name:					string,
	Reads:					{() -> any},
	Writes:					{(any) -> ()},
	ResponseTimeout:		number,
	ResponseTimeoutValue:	any,
	ResponseReads:			{() -> any},
	ResponseWrites:			{(any) -> ()},
	OnServerEvent:			Signal.Signal<(Player, A...)>,
	OnClientEvent:			Signal.Signal<A...>,
	OnServerInvoke:			nil | (player: Player, A...) -> B...,
	OnClientInvoke:			nil | (A...) -> B...,
	Response:				(self: Packet<A..., B...>, B...) -> Packet<A..., B...>,
	Fire:					(self: Packet<A..., B...>, A...) -> B...,
	FireClient:				(self: Packet<A..., B...>, player: Player, A...) -> B...,
	Serialize:				(self: Packet<A..., B...>, A...) -> (buffer, {Instance}?),
	Deserialize:			(self: Packet<A..., B...>, serializeBuffer: buffer, instances: {Instance}?) -> A...,
}


-- Varables
local ParametersToFunctions, TableToFunctions, ReadParameters, WriteParameters, Timeout
local RunService = game:GetService("RunService")
local PlayersService = game:GetService("Players")
local reads, writes, Import, Export, Truncate, Ended = Types.Reads, Types.Writes, Types.Import, Types.Export, Types.Truncate, Types.Ended
local ReadU8, WriteU8, ReadU16, WriteU16 = reads.NumberU8, writes.NumberU8, reads.NumberU16, writes.NumberU16
--[=[
	@class Packet

	A buffer-based networking library. Instead of one RemoteEvent per message, you declare
	named packets with a fixed list of value types; every `Fire` is serialised into a shared
	`buffer`, and everything queued during a frame is flushed through a single RemoteEvent.
	This gives far smaller payloads than sending Lua tables, and makes the shape of every
	message explicit.

	The module must live somewhere both sides can `require` (for example ReplicatedStorage):
	the server creates the RemoteEvent inside the module and the client waits for it.

	## Declaring packets

	`Packet.new(name, ...types)` declares a packet. Declare the same packet with the same name
	and types on the server and on the client (a shared ModuleScript is the easiest way).
	Declaring a name twice returns the existing packet. The value types are read from the
	module itself, e.g. `Packet.NumberU8`, `Packet.String`, `Packet.Vector3F32`.

	Plain Luau tables describe structured values:

	- `{ T }` (a table holding exactly one type) is a variable-length **array** of `T`
	  (up to 65535 elements, 2 bytes of length prefix).
	- Any other table, e.g. `{ Name = Packet.String, Level = Packet.NumberU8 }` or
	  `{ Packet.NumberU8, Packet.NumberU8 }`, is a **fixed table**: every key is always sent,
	  in sorted key order, with no per-field overhead. All keys must be of one kind (all
	  strings or all numbers), and tables can be nested.

	## Value types

	Numbers are not range-checked: writing a value outside the range of its type corrupts it,
	so pick the smallest type that fits.

	| Type | Bytes | Range / notes |
	|------|-------|---------------|
	| `NumberS8` | 1 | -128 to 127 |
	| `NumberS16` | 2 | -32768 to 32767 |
	| `NumberS24` | 3 | -8388608 to 8388607 |
	| `NumberS32` | 4 | -2147483648 to 2147483647 |
	| `NumberU8` | 1 | 0 to 255 |
	| `NumberU16` | 2 | 0 to 65535 |
	| `NumberU24` | 3 | 0 to 16777215 |
	| `NumberU32` | 4 | 0 to 4294967295 |
	| `NumberF16` | 2 | Half float; integers exact up to ±2048, largest value ±65520 |
	| `NumberF24` | 3 | Custom float; integers exact up to ±262144, largest value ±4294959104 |
	| `NumberF32` | 4 | Single float; integers exact up to ±16777216, largest value about ±1.7e38 |
	| `NumberF64` | 8 | Double float; integers exact up to ±9007199254740992, no practical limit |
	| `NumberU4` | 1 | `{number, number}`, two values from 0 to 15 packed in one byte |
	| `Boolean8` | 1 | A single `boolean` |
	| `Boolean1` | 1 | `{boolean}`, exactly eight booleans packed into one byte |
	| `BooleanNumber` | 1 | `{Boolean: boolean, Number: number}`, the number from 0 to 127 |
	| `String` | 1 + n | `string` of up to 255 bytes |
	| `StringLong` | 2 + n | `string` of up to 65535 bytes |
	| `Characters` | 1 + 6 bits/char | `string` of up to 255 characters using only space, `.`, `0-9`, `A-Z`, `a-z` (see `Types/Characters.luau`) |
	| `Buffer` | 1 + n | `buffer` of up to 255 bytes |
	| `BufferLong` | 2 + n | `buffer` of up to 65535 bytes |
	| `Instance` | 0 | `Instance`, sent alongside the buffer; arrives as `nil` if the receiver cannot see it |
	| `Nil` | 0 | Always `nil` |
	| `Any` | 1 + value | Any supported value, with a 1-byte type tag: `nil`, `number`, `string` (255 bytes max), `buffer` (255 bytes max), `Instance`, `boolean`, `NumberRange`, `BrickColor`, `Color3`, `UDim`, `UDim2`, `Rect`, `Vector2`, `Vector3`, `CFrame`, `Region3`, `NumberSequence`, `ColorSequence`, `EnumItem` (listed enums only) and tables whose keys and values are any of these |
	| `NumberRange` | 8 | Min and Max as F32 |
	| `BrickColor` | 2 | Any BrickColor |
	| `Color3` | 3 | 8 bits per channel |
	| `UDim` | 4 | Scale to 3 decimal places (±32.767), Offset -32768 to 32767 |
	| `UDim2` | 8 | Two `UDim`s as above |
	| `Rect` | 16 | Min and Max as F32 pairs |
	| `Vector2S16` | 4 | Components -32768 to 32767, integers only |
	| `Vector2F24` | 6 | Components as F24 |
	| `Vector2F32` | 8 | Components as F32 |
	| `Vector3S16` | 6 | Components -32768 to 32767, integers only |
	| `Vector3F24` | 9 | Components as F24 |
	| `Vector3F32` | 12 | Components as F32 |
	| `CFrameF24U8` | 12 | Position as F24, rotation as three 8-bit Euler angles (about 1.4 degree steps) |
	| `CFrameF32U8` | 15 | Position as F32, rotation as three 8-bit Euler angles (about 1.4 degree steps) |
	| `CFrameF32U16` | 18 | Position as F32, rotation as three 16-bit Euler angles (about 0.006 degree steps) |
	| `Region3` | 24 | Min and Max corners as F32 |
	| `NumberSequence` | 1 + 3n | Up to 255 keypoints; Time, Value and Envelope quantised to 1/255 (0 to 1 only) |
	| `ColorSequence` | 1 + 4n | Up to 255 keypoints; Time quantised to 1/255, colour 8 bits per channel |
	| `EnumItem` | 3 | Any item of an Enum listed in `Types/Enums.luau` (add more there, 255 max) |
	| `Static1`, `Static2`, `Static3` | 1 | A value from the matching `Types/Static1.luau` (etc.) list of up to 255 constants of any type; values not in the list arrive as `nil` |

	## Events and requests

	A packet without a response is an **event**: `Fire` on the client sends to the server and
	`OnServerEvent` fires there with the player first; `Fire` on the server broadcasts to every
	client and `FireClient(player, ...)` sends to one, firing `OnClientEvent`. Sends are
	batched and flushed once per frame, so `Fire` never yields for an event.

	Calling `:Response(...types)` on a packet (on both sides) turns it into a **request**: the
	receiving side must set `OnServerInvoke` / `OnClientInvoke`, and `Fire` (client) or
	`FireClient` (server) yields until the reply arrives or `ResponseTimeout` seconds pass,
	then returns the reply or `ResponseTimeoutValue`. Request packets do not fire the event
	signals.

	The server drops incoming data from a player that exceeds roughly 8 KB per frame (each
	received RemoteEvent call counts as at least 800 bytes), so keep client sends small.

	## Example

	```lua
	-- ReplicatedStorage/Packets.luau, required by both sides
	local Packet = require(ReplicatedStorage.Packages.Packet)

	return {
		-- client -> server: which hotbar slot was used and where the player aimed
		UseItem = Packet.new("UseItem", Packet.NumberU8, Packet.Vector3F32),
		-- server -> clients: an array of fixed tables
		Scores = Packet.new("Scores", {{Name = Packet.String, Score = Packet.NumberU16}}),
		-- client -> server request; the server answers with an array of strings
		GetInventory = Packet.new("GetInventory"):Response({Packet.String}),
	}
	```

	```lua
	-- Server
	local Packets = require(ReplicatedStorage.Packets)

	Packets.UseItem.OnServerEvent:Connect(function(player, slot, aimPosition)
		print(player.Name, "used slot", slot, "towards", aimPosition)
	end)

	Packets.GetInventory.OnServerInvoke = function(player)
		return {"Sword", "Shield"}
	end

	Packets.Scores:Fire({{Name = "Kash", Score = 10}, {Name = "Ana", Score = 7}})
	```

	```lua
	-- Client
	local Packets = require(ReplicatedStorage.Packets)

	Packets.Scores.OnClientEvent:Connect(function(scores)
		for _, entry in scores do print(entry.Name, entry.Score) end
	end)

	Packets.UseItem:Fire(1, workspace.CurrentCamera.CFrame.LookVector * 100)

	local inventory = Packets.GetInventory:Fire() -- yields until the server replies (10 s timeout)
	```

	Installation and guide: [Packet package page](/docs/packages/packet).
]=]
local Packet = {}			:: Packet<...any, ...any>
local packets = {}			:: {[string | number]: Packet<...any, ...any>}
local playerCursors			: {[Player]: Types.Cursor}
local playerThreads			: {[Player]: {[number]: {Yielded: thread, Timeout: thread}, Index: number}}
local threads				: {[number]: {Yielded: thread, Timeout: thread}, Index: number}
local remoteEvent			: RemoteEvent
local packetCounter			: number
local cursor = {Buffer = buffer.create(128), BufferLength = 128, BufferOffset = 0, Instances = {}, InstancesOffset = 0}


-- Constructor
local function Constructor<A..., B...>(_, name: string, ...: A...)
	local packet = packets[name] :: Packet<A..., B...>
	if packet then return packet end
	local packet = (setmetatable({}, Packet) :: any) :: Packet<A..., B...>
	packet.Name = name
	if RunService:IsServer() then
		packet.Id = packetCounter
		packet.OnServerEvent = Signal() :: Signal.Signal<(Player, A...)>
		remoteEvent:SetAttribute(name, packetCounter)
		packets[packetCounter] = packet
		packetCounter += 1
	else
		packet.Id = remoteEvent:GetAttribute(name)
		packet.OnClientEvent = Signal() :: Signal.Signal<A...>
		if packet.Id then packets[packet.Id] = packet end
	end
	packet.Reads, packet.Writes = ParametersToFunctions(table.pack(...))
	packets[packet.Name] = packet
	return packet
end


-- Packet
Packet["__index"] = Packet
Packet.Type = "Packet"

--[=[
	@prop Name string
	@within Packet
	@readonly
	The name the packet was declared with. Packets are cached by name, so declaring the same
	name again returns the same object.
]=]

--[=[
	@prop Id number
	@within Packet
	@readonly
	The one-byte id written at the start of every message for this packet. The server assigns
	it in declaration order and publishes it as an attribute on the RemoteEvent; on the client
	it is `nil` until the server has declared a packet with the same name.
]=]

--[=[
	@prop ResponseTimeout number
	@within Packet
	How many seconds `Fire` / `FireClient` wait for a reply on a request packet before giving
	up. `Response` sets it to `10` unless you assigned a value first; you can change it at any
	time.
]=]

--[=[
	@prop ResponseTimeoutValue any
	@within Packet
	What `Fire` / `FireClient` return when a request times out. Defaults to `nil`.
]=]

--[=[
	@prop OnServerEvent Signal<(Player, A...)>
	@within Packet
	@server
	@readonly
	Fires on the server when a client `Fire`s this event packet. Handlers receive the sending
	player followed by the packet's values. The signal has `Connect`, `Once` and `Wait`;
	`Connect` returns a connection with `Disconnect`. Not used by request packets.
]=]

--[=[
	@prop OnClientEvent Signal<A...>
	@within Packet
	@client
	@readonly
	Fires on the client when the server `Fire`s or `FireClient`s this event packet. Handlers
	receive the packet's values. The signal has `Connect`, `Once` and `Wait`; `Connect` returns
	a connection with `Disconnect`. Not used by request packets.
]=]

--[=[
	@prop OnServerInvoke ((player: Player, A...) -> B...)?
	@within Packet
	@server
	Callback the server must set on a request packet. It receives the requesting player and
	the packet's values and returns the response values. If it is `nil` when a request arrives
	the request is discarded (with a warning in Studio) and the client waits for its timeout.
]=]

--[=[
	@prop OnClientInvoke ((A...) -> B...)?
	@within Packet
	@client
	Callback the client must set on a request packet sent with `FireClient`. It receives the
	packet's values and returns the response values. If it is `nil` when a request arrives the
	request is discarded with a warning and the server waits for its timeout.
]=]

--[=[
	Declares the response types of the packet, turning it into a request/response packet.
	Call it on both sides, right after `Packet.new`, with the same syntax used for the packet's
	own types. Once a packet has a response, `Fire` (client) and `FireClient` (server) yield for
	the reply, the receiving side handles it through `OnServerInvoke` / `OnClientInvoke`, and
	the event signals are no longer fired.

	Also sets `ResponseTimeout` to `10` if it has not been set yet.

	```lua
	local GetStats = Packet.new("GetStats", Packet.NumberU16):Response(Packet.NumberU32, Packet.String)
	```

	@method Response
	@within Packet
	@param ... any -- The value types of the response, in order (see the class description).
	@return Packet<A..., B...> -- The same packet, for chaining.
]=]
function Packet:Response(...)
	self.ResponseTimeout = self.ResponseTimeout or 10
	self.ResponseReads, self.ResponseWrites = ParametersToFunctions(table.pack(...))
	return self
end

--[=[
	Sends the packet. Which way it goes depends on where it is called:

	- **Client**: sends to the server. For an event packet this returns immediately and
	  `OnServerEvent` fires on the server. For a request packet it yields until the server's
	  `OnServerInvoke` reply arrives and returns those values, or returns `ResponseTimeoutValue`
	  after `ResponseTimeout` seconds.
	- **Server**: broadcasts an event packet to every connected client (`OnClientEvent` fires
	  on each). Request packets cannot be broadcast; use `FireClient` instead.

	Sends are queued and flushed once per frame in a single RemoteEvent call, so nothing is
	transmitted until the end of the current frame.

	@method Fire
	@within Packet
	@yields
	@param ... A... -- The values to send, matching the types given to `Packet.new`.
	@return B... -- The response values (request packets only); nothing for event packets.
	@error "You must use FireClient(player)" -- When called on the server for a request packet.
	@error "Cannot have more than 128 yielded threads" -- When 128 requests from this client are already waiting for a reply.
]=]
function Packet:Fire(...)
	if self.ResponseReads then
		if RunService:IsServer() then error("You must use FireClient(player)", 2) end
		local responseThread
		for i = 1, 128 do
			responseThread = threads[threads.Index]
			if responseThread then threads.Index = (threads.Index + 1) % 128 else break end
		end
		if responseThread then error("Cannot have more than 128 yielded threads", 2) end
		Import(cursor)
		WriteU8(self.Id)
		WriteU8(threads.Index)
		threads[threads.Index] = {Yielded = coroutine.running(), Timeout = Task:Delay(self.ResponseTimeout, Timeout, threads, threads.Index, self.ResponseTimeoutValue)}
		threads.Index = (threads.Index + 1) % 128
		WriteParameters(self.Writes, {...})
		cursor = Export()
		return coroutine.yield()
	else
		Import(cursor)
		WriteU8(self.Id)
		WriteParameters(self.Writes, {...})
		cursor = Export()
	end
end

--[=[
	Sends the packet to one client. For an event packet this returns immediately and
	`OnClientEvent` fires on that client. For a request packet it yields until the client's
	`OnClientInvoke` reply arrives and returns those values, or returns `ResponseTimeoutValue`
	after `ResponseTimeout` seconds. If the player has already left the game nothing is sent
	and the call returns immediately with no values.

	Like `Fire`, the data is queued and flushed at the end of the frame.

	@method FireClient
	@within Packet
	@server
	@yields
	@param player Player -- The client to send to.
	@param ... A... -- The values to send, matching the types given to `Packet.new`.
	@return B... -- The response values (request packets only); nothing for event packets.
	@error "Cannot have more than 128 yielded threads" -- When 128 requests to this player are already waiting for a reply.
]=]
function Packet:FireClient(player, ...)
	if player.Parent == nil then return end
	if self.ResponseReads then
		local threads = playerThreads[player]
		if threads == nil then threads = {Index = 0} playerThreads[player] = threads end
		local responseThread
		for i = 1, 128 do
			responseThread = threads[threads.Index]
			if responseThread then threads.Index = (threads.Index + 1) % 128 else break end
		end
		if responseThread then error("Cannot have more than 128 yielded threads", 2) return end
		Import(playerCursors[player] or {Buffer = buffer.create(128), BufferLength = 128, BufferOffset = 0, Instances = {}, InstancesOffset = 0})
		WriteU8(self.Id)
		WriteU8(threads.Index)
		threads[threads.Index] = {Yielded = coroutine.running(), Timeout = Task:Delay(self.ResponseTimeout, Timeout, threads, threads.Index, self.ResponseTimeoutValue)}
		threads.Index = (threads.Index + 1) % 128
		WriteParameters(self.Writes, {...})
		playerCursors[player] = Export()
		return coroutine.yield()
	else
		Import(playerCursors[player] or {Buffer = buffer.create(128), BufferLength = 128, BufferOffset = 0, Instances = {}, InstancesOffset = 0})
		WriteU8(self.Id)
		WriteParameters(self.Writes, {...})
		playerCursors[player] = Export()
	end
end

--[=[
	Encodes values with this packet's types into a standalone `buffer` without sending
	anything, using the same format as `Fire`. Useful for compact storage (for example in a
	DataStore) or for sending through your own remotes. Works on either side.

	```lua
	local SaveData = Packet.new("SaveData", Packet.NumberU32, {Packet.String})
	local data = SaveData:Serialize(1500, {"Sword", "Shield"})
	local coins, items = SaveData:Deserialize(data)
	```

	@method Serialize
	@within Packet
	@param ... A... -- The values to encode, matching the types given to `Packet.new`.
	@return buffer -- The encoded bytes, sized exactly to the data.
	@return {Instance}? -- The Instances that were referenced, in order; only returned when at least one `Instance` was written.
]=]
function Packet:Serialize(...)
	Import({Buffer = buffer.create(128), BufferLength = 128, BufferOffset = 0, Instances = {}, InstancesOffset = 0})
	WriteParameters(self.Writes, {...})
	return Truncate()
end

--[=[
	Decodes a buffer produced by `Serialize` on a packet with the same types, returning the
	original values. Works on either side.

	@method Deserialize
	@within Packet
	@param serializeBuffer buffer -- A buffer returned by `Serialize`.
	@param instances {Instance}? -- The Instance list returned by `Serialize`, if there was one.
	@return A... -- The decoded values, in the order the packet declares them.
]=]
function Packet:Deserialize(serializeBuffer, instances)
	Import({Buffer = serializeBuffer, BufferLength = buffer.len(serializeBuffer), BufferOffset = 0, Instances = instances or {}, InstancesOffset = 0})
	return ReadParameters(self.Reads)
end


-- Functions
function ParametersToFunctions(parameters: {any})
	local readFunctions, writeFunctions = table.create(#parameters), table.create(#parameters)
	for index, parameter in ipairs(parameters) do
		if type(parameter) == "table" then
			readFunctions[index], writeFunctions[index] = TableToFunctions(parameter)
		else
			readFunctions[index], writeFunctions[index] = reads[parameter], writes[parameter]
		end
	end
	return readFunctions, writeFunctions
end

function TableToFunctions(parameters: {any})
	if #parameters == 1 then
		local parameter = parameters[1]
		local ReadFunction, WriteFunction
		if type(parameter) == "table" then
			ReadFunction, WriteFunction = TableToFunctions(parameter)
		else
			ReadFunction, WriteFunction = reads[parameter], writes[parameter]
		end
		local Read = function()
			local length = ReadU16()
			local values = table.create(length)
			for index = 1, length do values[index] = ReadFunction() end
			return values
		end
		local Write = function(values: {any})
			WriteU16(#values)
			for index, value in values do WriteFunction(value) end
		end
		return Read, Write
	else
		local keys = {} for key, value in parameters do table.insert(keys, key) end table.sort(keys)
		local readFunctions, writeFunctions = table.create(#keys), table.create(#keys)
		for index, key in keys do
			local parameter = parameters[key]
			if type(parameter) == "table" then 
				readFunctions[index], writeFunctions[index] = TableToFunctions(parameter)
			else
				readFunctions[index], writeFunctions[index] = reads[parameter], writes[parameter]
			end
		end
		local Read = function()
			local values = {}
			for index, ReadFunction in readFunctions do values[keys[index]] = ReadFunction() end
			return values
		end
		local Write = function(values: {[any]: any})
			for index, WriteFunction in writeFunctions do WriteFunction(values[keys[index]]) end
		end
		return Read, Write
	end
end

function ReadParameters(reads: {() -> any})
	local values = table.create(#reads)
	for index, func in reads do values[index] = func() end
	return table.unpack(values)
end

function WriteParameters(writes: {(any) -> ()}, values: {any})
	for index, func in writes do func(values[index]) end
end

function Timeout(threads: {[number]: {Yielded: thread, Timeout: thread}, Index: number}, threadIndex: number, value: any)
	local responseThreads = threads[threadIndex]
	task.defer(responseThreads.Yielded, value)
	threads[threadIndex] = nil
end


-- Initialize
if RunService:IsServer() then
	playerCursors = {}
	playerThreads = {}
	packetCounter = 0
	remoteEvent = Instance.new("RemoteEvent", script)

	local playerBytes = {}

	local thread = task.spawn(function()
		while true do
			coroutine.yield()
			if cursor.BufferOffset > 0 then
				local truncatedBuffer = buffer.create(cursor.BufferOffset)
				buffer.copy(truncatedBuffer, 0, cursor.Buffer, 0, cursor.BufferOffset)
				if cursor.InstancesOffset == 0 then
					remoteEvent:FireAllClients(truncatedBuffer)
				else
					remoteEvent:FireAllClients(truncatedBuffer, cursor.Instances)
					cursor.InstancesOffset = 0
					table.clear(cursor.Instances)
				end
				cursor.BufferOffset = 0
			end
			for player, cursor in playerCursors do
				local truncatedBuffer = buffer.create(cursor.BufferOffset)
				buffer.copy(truncatedBuffer, 0, cursor.Buffer, 0, cursor.BufferOffset)
				if cursor.InstancesOffset == 0 then
					remoteEvent:FireClient(player, truncatedBuffer)
				else
					remoteEvent:FireClient(player, truncatedBuffer, cursor.Instances)
				end
			end
			table.clear(playerCursors)
			table.clear(playerBytes)
		end
	end)

	local respond = function(packet: Packet, player: Player, threadIndex: number, ...)
		if packet.OnServerInvoke == nil then if RunService:IsStudio() then warn("OnServerInvoke not found for packet:", packet.Name, "discarding event:", ...) end return end
		local values = {packet.OnServerInvoke(player, ...)}
		if player.Parent == nil then return end
		Import(playerCursors[player] or {Buffer = buffer.create(128), BufferLength = 128, BufferOffset = 0, Instances = {}, InstancesOffset = 0})
		WriteU8(packet.Id)
		WriteU8(threadIndex + 128)
		WriteParameters(packet.ResponseWrites, values)
		playerCursors[player] = Export()
	end
	
	local onServerEvent = function(player: Player, receivedBuffer: buffer, instances: {Instance}?)
		local bytes = (playerBytes[player] or 0) + math.max(buffer.len(receivedBuffer), 800)
		if bytes > 8_000 then if RunService:IsStudio() then warn(player.Name, "is exceeding the data/rate limit; some events may be dropped") end return end
		playerBytes[player] = bytes
		Import({Buffer = receivedBuffer, BufferLength = buffer.len(receivedBuffer), BufferOffset = 0, Instances = instances or {}, InstancesOffset = 0})
		while Ended() == false do
			local packet = packets[ReadU8()]
			if packet.ResponseReads then
				local threadIndex = ReadU8()
				if threadIndex < 128 then
					Task:Defer(respond, packet, player, threadIndex, ReadParameters(packet.Reads))
				else
					threadIndex -= 128
					local responseThreads = playerThreads[player][threadIndex]
					if responseThreads then
						task.cancel(responseThreads.Timeout)
						task.defer(responseThreads.Yielded, ReadParameters(packet.ResponseReads))
						playerThreads[player][threadIndex] = nil
					elseif RunService:IsStudio() then
						warn("Response thread not found for packet:", packet.Name, "discarding response:", ReadParameters(packet.ResponseReads))
					else
						ReadParameters(packet.ResponseReads)
					end
				end
			else
				packet.OnServerEvent:Fire(player, ReadParameters(packet.Reads))
			end
		end
	end

	remoteEvent.OnServerEvent:Connect(function(player: Player, ...)
		local success, errorMessage: string? = pcall(onServerEvent, player, ...)
		if errorMessage and RunService:IsStudio() then warn(player.Name, errorMessage) end
	end)

	PlayersService.PlayerRemoving:Connect(function(player)
		playerCursors[player] = nil
		playerThreads[player] = nil
		playerBytes[player] = nil
	end)

	RunService.Heartbeat:Connect(function(deltaTime) task.defer(thread) end)
else
	threads = {Index = 0}
	remoteEvent = script:WaitForChild("RemoteEvent")
	local totalTime = 0

	local thread = task.spawn(function()
		while true do
			coroutine.yield()
			if cursor.BufferOffset > 0 then
				local truncatedBuffer = buffer.create(cursor.BufferOffset)
				buffer.copy(truncatedBuffer, 0, cursor.Buffer, 0, cursor.BufferOffset)
				if cursor.InstancesOffset == 0 then
					remoteEvent:FireServer(truncatedBuffer)
				else
					remoteEvent:FireServer(truncatedBuffer, cursor.Instances)
					cursor.InstancesOffset = 0
					table.clear(cursor.Instances)
				end
				cursor.BufferOffset = 0
			end
		end
	end)

	local respond = function(packet: Packet, threadIndex: number, ...)
		if packet.OnClientInvoke == nil then warn("OnClientInvoke not found for packet:", packet.Name, "discarding event:", ...) return end
		local values = {packet.OnClientInvoke(...)}
		Import(cursor)
		WriteU8(packet.Id)
		WriteU8(threadIndex + 128)
		WriteParameters(packet.ResponseWrites, values)
		cursor = Export()
	end

	remoteEvent.OnClientEvent:Connect(function(receivedBuffer: buffer, instances: {Instance}?)
		Import({Buffer = receivedBuffer, BufferLength = buffer.len(receivedBuffer), BufferOffset = 0, Instances = instances or {}, InstancesOffset = 0})
		while Ended() == false do
			local packet = packets[ReadU8()]
			if packet.ResponseReads then
				local threadIndex = ReadU8()
				if threadIndex < 128 then
					Task:Defer(respond, packet, threadIndex, ReadParameters(packet.Reads))
				else
					threadIndex -= 128
					local responseThreads = threads[threadIndex]
					if responseThreads then
						task.cancel(responseThreads.Timeout)
						task.defer(responseThreads.Yielded, ReadParameters(packet.ResponseReads))
						threads[threadIndex] = nil
					else
						warn("Response thread not found for packet:", packet.Name, "discarding response:", ReadParameters(packet.ResponseReads))
					end
				end
			else
				packet.OnClientEvent:Fire(ReadParameters(packet.Reads))
			end
		end
	end)

	remoteEvent.AttributeChanged:Connect(function(name)
		local packet = packets[name]
		if packet then
			if packet.Id then packets[packet.Id] = nil end
			packet.Id = remoteEvent:GetAttribute(name)
			if packet.Id then packets[packet.Id] = packet end
		end
	end)

	RunService.Heartbeat:Connect(function(deltaTime)
		totalTime += deltaTime
		if totalTime > 0.016666666666666666 then
			totalTime %= 0.016666666666666666
			task.defer(thread)
		end
	end)
end

--[=[
	Declares a packet, or returns the one already declared with that name. Declare it on both
	the server and the client with identical types. The types are the `Packet.*` value types
	listed in the class description, or Luau tables of them for arrays and fixed tables.

	On the server this assigns the packet's `Id` and publishes it to clients; on the client the
	packet is inert until the server has declared the same name. This is the only way to
	declare a packet: the module table itself is not callable.

	```lua
	local Damage = Packet.new("Damage", Packet.Instance, Packet.NumberU16)
	local Spawn = Packet.new("Spawn", {Position = Packet.Vector3F32, Skin = Packet.NumberU8})
	local Ping = Packet.new("Ping"):Response(Packet.NumberF32)
	```

	@function new
	@within Packet
	@param name string -- A unique name for the packet, shared by both sides.
	@param ... any -- The value types of the packet, in order (none for a packet without data).
	@return Packet<A..., B...> -- The packet object.
]=]
local function new<A...>(name: string, ...: A...)
	return Constructor(Packet, name, ...)
end

--[=[
	Bundles a list of value types into a function that returns them, so the same parameter
	list can be reused across several packets or shared between a request and its response.
	Call the returned function inside `Packet.new` or `Response` to expand it.

	```lua
	local Position = Packet.newParams(Packet.NumberU8, Packet.Vector3F32)
	local Move = Packet.new("Move", Position())
	local Teleport = Packet.new("Teleport", Position()):Response(Position())
	```

	@function newParams
	@within Packet
	@param ... any -- The value types to bundle, in order.
	@return () -> ...any -- A function that returns the bundled types.
]=]
local function newParams<A...>(...: A...): ()->...any
	local args = table.pack(...)
	
	return function()
		return unpack(args)
	end
end

return setmetatable(
	{
		new = new,
		newParams = newParams
	},
	{__index = setmetatable(Types.Types, {__call = Constructor})}
)
--!strict
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IS_SERVER = RunService:IsServer()

--[=[
	@class Authority

	A server-authoritative state object whose fields replicate to clients through attributes on an
	instance. You create it on both sides from the same module with the same default table; the
	server owns the values and the clients receive them.

	How it works:
	- Each key of `properties` becomes a field. Its initial value is the matching attribute on
	  `parent` if one exists, otherwise the default you passed in.
	- **Server**: writing `authority.Key = value` stores the value and calls
	  `parent:SetAttribute("Key", value)`, which Roblox replicates. All defaults are written to the
	  attributes as soon as the object is created. Only string keys can be attributes; other keys
	  are kept locally with a warning.
	- **Client**: writing any field errors. Reading returns the latest value, which is kept in sync
	  by listening to `parent.AttributeChanged`, so clients see server writes without any remotes.
	- Both sides also pick up attribute changes made outside the object (for example from the
	  Studio properties panel) for keys that are currently tracked.

	```lua
	-- ReplicatedStorage/MatchState.luau (required by both server and client)
	local Authority = require(path.to.Authority)

	return Authority(workspace, {
		Phase = "Lobby",
		TimeLeft = 60,
	})
	```

	```lua
	-- Server
	local MatchState = require(ReplicatedStorage.MatchState)
	MatchState.Phase = "Playing"      -- sets workspace attribute "Phase", replicates
	MatchState.TimeLeft -= 1

	-- Client
	local MatchState = require(ReplicatedStorage.MatchState)
	print(MatchState.Phase)           -- "Playing" once replicated
	workspace:GetAttributeChangedSignal("TimeLeft"):Connect(function()
		print(MatchState.TimeLeft)
	end)
	```

	Setting a field to `nil` on the server removes the attribute and the object stops tracking that
	key, so prefer sentinel values over `nil` for optional state. Do not use `Destroy` as a key; it is
	reserved for the cleanup method.

	Installation and guide: [Authority package page](/docs/packages/authority).
]=]

--[=[
	@interface AuthorityObject
	@within Authority
	.Destroy (self: Authority<A>) -> () -- Disconnects the attribute listener and disables the object. See [Authority:Destroy](#Destroy).

	The object returned by [Authority.new](#new): all the fields of your `properties` table `A`
	(read on both sides, written on the server only) plus `Destroy`. It is a userdata proxy, not a
	table, so you cannot iterate it or use `rawget`/`rawset` on it.
]=]
export type Authority<A = {}> = A & {
	Destroy: (self: Authority<A>)->()
}

--[=[
	Stops listening to `parent.AttributeChanged` and removes every metamethod from the proxy, so
	any later field access errors. The attributes already written to `parent` are left in place.
	Call it when the state is no longer needed, for example when `parent` is about to be destroyed.

	@method Destroy
	@within Authority
]=]

--[=[
	Creates an Authority whose fields mirror attributes on `parent`. Call it on both the server
	and the client with the same defaults. The module itself is this function, so use
	`Authority(parent, properties)`.

	On the server every default is immediately written to `parent` as an attribute (existing
	attributes win over defaults), and subsequent writes to the object replicate the same way. On
	the client the object is read-only and follows the server's attribute values.

	@function new
	@within Authority
	@param parent Instance -- The instance whose attributes carry the state. It must replicate to the clients that need the values (e.g. under `workspace` or `ReplicatedStorage`).
	@param properties A -- Dictionary of default values. Keys must be strings to replicate; values must be attribute-compatible types.
	@return Authority<A> -- A proxy exposing `properties`' fields plus `Destroy`.
	@error "Parent must a valid instance" -- `parent` is not an Instance.
	@error "Properties must be a valid dictionary" -- `properties` is not a table.
	@error "Client attempted to change server key" -- Raised later, when a client assigns to any field of the returned object.
]=]
return function<A>(parent: Instance, _properties: A): Authority<A>
	assert(typeof(parent) == "Instance", "Parent must a valid instance")
	assert(type(_properties) == "table", "Properties must be a valid dictionary")

	local state: any = {}
	
	local destroyed = false
	local connection: RBXScriptConnection

	local interface = newproxy(true)
	local interfaceMt = getmetatable(interface)

	for key, default in _properties :: any do
		local attr = parent:GetAttribute(key)
		state[key] = if attr ~= nil then attr else default
	end

	local function push(key: string, value: any)
		if not IS_SERVER then return end
		if type(key) ~= "string" then return end
		parent:SetAttribute(key, value)
	end
	
	local function cleanup()
		destroyed = true
		connection:Disconnect()
		
		for key in interfaceMt do
			interfaceMt[key] = nil
		end
	end

	interfaceMt.__index = function(_, key)
		assert(destroyed == false, "Attempt to index property on destroyed authority", 2)
		
		if key == "Destroy" then
			return cleanup
		end
		
		return state[key]
	end
	
	interfaceMt.__newindex = function(_, key, value)
		if not IS_SERVER then
			error(`Client attempted to change server key "{key}"`, 2)
		end

		rawset(state, key, value)

		if IS_SERVER then
			push(key, value)
		end
	end

	local function onAttributeChanged(key: string)
		if state[key] == nil then return end

		local value = parent:GetAttribute(key)
		state[key] = value
		
		push(key, value)
	end

	connection = parent.AttributeChanged:Connect(onAttributeChanged)

	if IS_SERVER then
		for key, value in state do
			if type(key) ~= "string" then
				warn(`"{key}" is not type "string" so it won't be replicated.`)
				continue
			end
			
			if key == "Destroy" then
				warn(`"Destroy" can't be used as a key, it will override the cleanup method.`)
			end
			
			push(key, value)
		end
	end

	return interface :: A & {Destroy: (self: Authority<A>)->()}
end

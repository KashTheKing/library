--!strict
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IS_SERVER = RunService:IsServer()

export type Authority<A = {}> = A & {
	Destroy: (self: Authority<A>)->()
}

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

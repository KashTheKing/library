-- A stand-in for kashtheking/packet with the same surface Stagger uses. Sends are delivered
-- synchronously across the BRIDGE shared by both peers.
local RunService = game:GetService("RunService")
local isServer = RunService:IsServer()
local Signal = require(script.Parent.Signal)

local BRIDGE = (_G_BRIDGE :: any)
local side = if isServer then "server" else "client"
BRIDGE[side] = BRIDGE[side] or {}

local Packet = {}
Packet.__index = Packet

function Packet:Fire(...)
	BRIDGE.log[#BRIDGE.log + 1] = { side = side, name = self.Name, args = table.pack(...) }
	if isServer then
		local other = BRIDGE.client and BRIDGE.client[self.Name]
		if other then local prev = BRIDGE.setCurrent("client"); other.OnClientEvent:Fire(...); BRIDGE.setCurrent(prev) end
	else
		local other = BRIDGE.server and BRIDGE.server[self.Name]
		if other then local prev = BRIDGE.setCurrent("server"); other.OnServerEvent:Fire(BRIDGE.localPlayer, ...); BRIDGE.setCurrent(prev) end
	end
end

function Packet:FireClient(player, ...)
	BRIDGE.log[#BRIDGE.log + 1] = { side = side, name = self.Name, player = player, args = table.pack(...) }
	local other = BRIDGE.client and BRIDGE.client[self.Name]
	if other and player == BRIDGE.localPlayer then local prev = BRIDGE.setCurrent("client"); other.OnClientEvent:Fire(...); BRIDGE.setCurrent(prev) end
end

local function new(name, ...)
	local existing = BRIDGE[side][name]
	if existing then return existing end
	local p = setmetatable({ Name = name, Types = table.pack(...), OnServerEvent = Signal.new(), OnClientEvent = Signal.new() }, Packet)
	BRIDGE[side][name] = p
	return p
end

return setmetatable({ new = new }, { __index = function(_, k) return "TYPE:" .. k end })

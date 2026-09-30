--!strict
--[=[
	@class Packets
	@ignore
	The two packets Stagger uses, declared with kashtheking/packet on both sides.
]=]
local Packet = require(script.Parent.Parent.Packet)

return {
	-- Server -> every client: a character changed state.
	-- character, state, direction, seed, intensity, preset, driver UserId (0: the server, or the
	-- character's own player)
	State = Packet.new("Stagger.State", Packet.Instance, Packet.NumberU8, Packet.Vector3F32, Packet.NumberU16, Packet.NumberF32, Packet.String, Packet.NumberF64),

	-- Client (the character's driver) -> server: the balance model decided.
	-- character, state (Ragdoll or Recovering)
	Report = Packet.new("Stagger.Report", Packet.Instance, Packet.NumberU8),
}

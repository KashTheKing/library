--!nonstrict
-- Sample helpers and activity for the stories (story-only; the plugin never uses this).

local Mock = {}

Mock.Agents = {
	{ id = "a1", name = "Claude", color = "#FF8A3D", kind = "agent", status = "SetKeyframe", stopped = false },
	{ id = "a2", name = "Claude 2", color = "#2EC4B6", kind = "agent", status = "idle", stopped = false },
	{ id = "a3", name = "Legs", color = "#FF5CA8", kind = "agent", status = "Batch", stopped = true },
	{ id = "a4", name = "Panel", color = "#FFC93D", kind = "webhook", status = "idle", stopped = false },
}

Mock.Leases = {
	{ key = "Workspace/Rig/Head", agentId = "a1" },
	{ key = "Workspace/Rig/Torso", agentId = "a1" },
	{ key = "Workspace/Rig/LeftLeg", agentId = "a3" },
}

Mock.Activity = {
	{ type = "joined", agent = Mock.Agents[1] },
	{ type = "joined", agent = Mock.Agents[2] },
	{ type = "call", agent = "Claude", color = "#FF8A3D", ok = true, summary = "Batch Idle breath in (12 edits)" },
	{ type = "claim", agent = "Legs", color = "#FF5CA8", keys = { "Workspace/Rig/LeftLeg" } },
	{ type = "call", agent = "Claude 2", color = "#2EC4B6", ok = false, summary = "SetKeyframe Head @12", error = "Claude is working on Workspace/Rig/Head" },
	{ type = "call", agent = "Claude", color = "#FF8A3D", ok = true, summary = "SetKeyframe Head @24" },
}

return Mock

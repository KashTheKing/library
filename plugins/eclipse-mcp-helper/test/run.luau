-- Plugin tests. Build first, then: lune run test/run.luau build/EclipseMCPHelper.rbxm
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local H = require("./harness")

local path = process.args[1] or "build/EclipseMCPHelper.rbxm"
local CFrame, Vector3 = roblox.CFrame, roblox.Vector3

-- A fake Eclipse session that records every request and answers like the real API.
local function fakeEclipse()
	local calls = {}
	local history = { UndoCount = 0, RedoCount = 0 }
	local endpoint = {
		session = "Session-test",
		version = 6,
		invoke = function(action, request)
			table.insert(calls, { action = action, request = request })
			if action == "Batch" then
				history.UndoCount += 1
				history.RedoCount = 0
				local results = {}
				for i, step in request.Actions do
					results[i] = { Target = step.Request.Target, Frame = step.Request.Frame }
				end
				return true, { Name = request.Name, Results = results }
			elseif action == "GetHistoryState" then
				return true, { UndoCount = history.UndoCount, RedoCount = history.RedoCount, CanUndo = history.UndoCount > 0 }
			elseif action == "Undo" then
				history.UndoCount -= 1
				history.RedoCount += 1
				return true, { UndoCount = history.UndoCount, RedoCount = history.RedoCount, Changed = true }
			elseif action == "Redo" then
				history.UndoCount += 1
				history.RedoCount -= 1
				return true, { UndoCount = history.UndoCount, RedoCount = history.RedoCount, Changed = true }
			elseif action == "ForwardInput" then
				return true, { Handled = true }
			elseif action == "GetInfo" then
				return true, { Version = 6, Active = true }
			elseif action == "ListTracks" then
				return true, {}
			end
			return true, { action = action }
		end,
	}
	return endpoint, calls, history
end

local endpoint, calls, history = fakeEclipse()
local EclipseStub = {
	MinVersion = 6,
	pick = function()
		return endpoint
	end,
	sessions = function()
		return { endpoint }
	end,
}

local P = H.load(path, { Eclipse = EclipseStub })
local Codec = P.require("Codec")
local Ownership = P.require("Ownership")
local Commands = P.require("Commands")
local Keybinds = P.require("Keybinds")

-- A tiny rig: Rig > Torso, Head, with a Motor6D Neck driving Head.
local rig = roblox.Instance.new("Model")
rig.Name = "Rig"
rig.Parent = P.workspace
local torso = roblox.Instance.new("Part")
torso.Name = "Torso"
torso.Parent = rig
local head = roblox.Instance.new("Part")
head.Name = "Head"
head.Parent = rig
local neck = roblox.Instance.new("Motor6D")
neck.Name = "Neck"
neck.Part0, neck.Part1 = torso, head
neck.C0 = CFrame.new(0, 1, 0)
neck.Transform = CFrame.new() -- Lune has no default for this runtime-only property; Studio does
neck.Parent = torso
roblox.Instance.new("Humanoid").Parent = rig

local touched = {}
local ctx = {
	root = P.game,
	ownership = Ownership.new(),
	selection = function()
		return { head }
	end,
	touch = function(agent, targets, note)
		table.insert(touched, { agent = agent.name, count = #targets, note = note })
	end,
	human = function()
		return { name = "Kash" }
	end,
	busy = false,
}
local claude = { id = "a1", name = "Claude", color = "#FF8A3D" }
local other = { id = "a2", name = "Claude 2", color = "#2EC4B6" }

local function run(agent, op, args, force)
	return Commands.run(ctx, { id = "c", op = op, args = args, agent = agent, force = force })
end

H.test("CFrames, vectors, colors and enums round-trip", function()
	local cf = CFrame.new(1, 2, 3) * CFrame.fromOrientation(math.rad(10), math.rad(20), math.rad(30))
	local enc = Codec.encode(cf, P.game)
	H.eq(#enc["$cf"], 12)
	H.eq(enc.p[2], 2)
	local back = Codec.decode(enc, P.game)
	H.eq((back.Position - cf.Position).Magnitude < 1e-5, true, "position")
	local fromPR = Codec.decode({ ["$cf"] = { p = { 1, 2, 3 }, r = { 10, 20, 30 } } }, P.game)
	H.eq((fromPR.LookVector - cf.LookVector).Magnitude < 1e-5, true, "p/r form matches Orientation")
	H.eq(Codec.decode({ ["$v3"] = { 1, 2, 3 } }, P.game), Vector3.new(1, 2, 3))
	H.eq(Codec.encode(roblox.Enum.EasingStyle.Quad, P.game)["$enum"], "EasingStyle.Quad")
	H.eq(Codec.decode({ ["$enum"] = "EasingStyle.Quad" }, P.game), roblox.Enum.EasingStyle.Quad)
	H.eq(Codec.decode({ ["$c3"] = { 1, 0, 0 } }, P.game), roblox.Color3.new(1, 0, 0))
end)

H.test("instances travel as paths and come back", function()
	local enc = Codec.encode(head, P.game)
	H.eq(table.concat(enc["$inst"], "/"), "Workspace/Rig/Head")
	H.eq(enc.class, "Part")
	H.eq(Codec.decode(enc, P.game), head)
	H.eq(Codec.decode({ ["$id"] = enc.id }, P.game), head, "by id")
	local req = Codec.decode({ Target = "Workspace.Rig.Head", Parent = "folder_123", Name = "Workspace.Rig" }, P.game)
	H.eq(req.Target, head, "Target string is a path")
	H.eq(req.Parent, "folder_123", "folder ids stay strings")
	H.eq(req.Name, "Workspace.Rig", "other strings stay text")
	H.eq(pcall(Codec.decode, { Target = "Workspace.Nope" }, P.game), false, "missing paths fail")
	H.eq(pcall(Codec.decode, { ["$cf"] = { 1, 2 } }, P.game), false, "bad CFrame fails")
end)

H.test("a keyframe edit carries the helper's name into Eclipse's history and lights up the target", function()
	table.clear(calls)
	local ok, result, summary = run(claude, "eclipse.invoke", {
		action = "SetKeyframe",
		request = { Target = "Workspace.Rig.Head", Frame = 12, Value = { ["$cf"] = { p = { 0, 1, 0 } } } },
	})
	H.eq(ok, true, tostring(result))
	local batch
	for _, c in calls do
		if c.action == "Batch" then
			batch = c
		end
	end
	H.eq(batch.request.Name, "Claude: SetKeyframe Head @12")
	H.eq(batch.request.Actions[1].Action, "SetKeyframe")
	H.eq(batch.request.Actions[1].Request.Target, head)
	H.eq(result.Frame, 12)
	H.eq(summary, "SetKeyframe Head @12")
	H.eq(touched[#touched].agent, "Claude")
	H.eq(ctx.ownership.undo[#ctx.ownership.undo].agent, "a1", "the step is Claude's")
end)

H.test("offset keys the joint's current C0 times the offset", function()
	table.clear(calls)
	local ok, err = run(claude, "eclipse.invoke", {
		action = "SetKeyframe",
		request = { Target = "Workspace.Rig.Head", Frame = 4, Offset = { ["$cf"] = { p = { 0, 0, 0 }, r = { 0, 0, 30 } } } },
	})
	H.eq(ok, true, tostring(err))
	local req = calls[#calls - 1].request.Actions[1].Request
	H.eq(req.Offset, nil)
	local want = neck.C0 * CFrame.fromOrientation(0, 0, math.rad(30))
	H.eq((req.Value.Position - want.Position).Magnitude < 1e-5 and (req.Value.UpVector - want.UpVector).Magnitude < 1e-5, true)
end)

H.test("a Motor6D target (what ListTracks returns) offsets from its own C0", function()
	table.clear(calls)
	local ok, err = run(claude, "eclipse.invoke", {
		action = "SetKeyframe",
		request = { Target = "Workspace.Rig.Torso.Neck", Frame = 6, Offset = { ["$cf"] = { p = { 0, 0, 0 }, r = { 0, 25, 0 } } } },
	})
	H.eq(ok, true, tostring(err))
	local req = calls[#calls - 1].request.Actions[1].Request
	H.eq(req.Target, neck)
	local want = neck.C0 * CFrame.fromOrientation(0, math.rad(25), 0)
	H.eq((req.Value.LookVector - want.LookVector).Magnitude < 1e-5, true)
end)

H.test("keys on the real rig land on Eclipse's preview clone of it", function()
	local camera = roblox.Instance.new("Camera")
	camera.Parent = P.workspace
	P.workspace.CurrentCamera = camera
	local preview = roblox.Instance.new("Model")
	preview.Name = "EclipseLivePreview"
	preview.Parent = camera
	local clone = rig:Clone()
	clone.Parent = preview
	local cloneNeck = clone:FindFirstChild("Torso"):FindFirstChild("Neck")
	table.clear(calls)
	local ok, err = run(claude, "eclipse.invoke", { action = "SetKeyframe", request = { Target = "Workspace.Rig.Torso.Neck", Frame = 2, Value = { ["$cf"] = { p = { 0, 1, 0 }, r = { 0, 0, 0 } } } } })
	H.eq(ok, true, tostring(err))
	H.eq(calls[#calls - 1].request.Actions[1].Request.Target, cloneNeck)
	-- Reads and AddObject keep the real instance.
	run(claude, "eclipse.invoke", { action = "ListProperties", request = { Target = "Workspace.Rig" } })
	H.eq(calls[#calls].request.Target, rig)
	preview:Destroy()
end)

H.test("batches get the helper's name; shared batches and raw undo are refused", function()
	local ok = run(claude, "eclipse.invoke", { action = "Batch", request = { Name = "Idle pose", Actions = { { Action = "SetKeyframe", Request = { Target = "Workspace.Rig.Torso", Frame = 0 } } } } })
	H.eq(ok, true)
	H.eq(calls[#calls - 1].request.Name, "Claude: Idle pose")
	H.eq((run(claude, "eclipse.invoke", { action = "BeginBatch", request = {} })), false)
	H.eq((run(claude, "eclipse.invoke", { action = "Undo", request = {} })), false)
end)

H.test("reads pass straight through without wrapping", function()
	table.clear(calls)
	local ok, result = run(claude, "eclipse.invoke", { action = "ListProperties", request = { Target = "Workspace.Rig" } })
	H.eq(ok, true)
	H.eq(calls[1].action, "ListProperties")
	H.eq(calls[1].request.Target, rig)
	H.eq(result.action, "ListProperties")
end)

H.test("helpers only undo their own newest step, never Kash's or another helper's", function()
	ctx.ownership = Ownership.new()
	history.UndoCount, history.RedoCount = 0, 0
	run(claude, "eclipse.invoke", { action = "SetKeyframe", request = { Target = "Workspace.Rig.Head", Frame = 1 } })
	local ok, err = run(other, "eclipse.history", { op = "undo" })
	H.eq(ok, false)
	H.eq(string.find(err, "another helper") ~= nil, true, err)
	-- Kash edits: the newest step is now his.
	history.UndoCount += 1
	ok, err = run(claude, "eclipse.history", { op = "undo" })
	H.eq(ok, false, "Kash's step protected")
	history.UndoCount -= 1 -- Kash undid his own edit
	ok, err = run(claude, "eclipse.history", { op = "undo" })
	H.eq(ok, true, tostring(err))
	ok = run(other, "eclipse.history", { op = "redo" })
	H.eq(ok, false, "can't redo someone else's undo")
	ok, err = run(claude, "eclipse.history", { op = "redo" })
	H.eq(ok, true, tostring(err))
	local ok2, state = run(claude, "eclipse.history", { op = "state" })
	H.eq(ok2, true)
	H.eq(state.NewestStepIsYours, true)
end)

H.test("commands press Eclipse's default keys; undo keys are refused", function()
	table.clear(calls)
	local ok, result = run(claude, "eclipse.command", { command = "TogglePlayback" })
	H.eq(ok, true, tostring(result))
	H.eq(calls[2].action, "ForwardInput")
	H.eq(calls[2].request.Key, Keybinds.TogglePlayback.Key)
	H.eq(Keybinds.TogglePlayback.Key, "Space")
	ok, result = run(claude, "eclipse.command", { command = "StepFrameRight", ["repeat"] = 3 })
	H.eq(result.Presses, 3)
	H.eq((run(claude, "eclipse.command", { command = "Undo" })), false)
	H.eq((run(claude, "eclipse.command", { command = "Nope" })), false)
	ok, result = run(claude, "eclipse.command", { key = "K", modifiers = { "Shift" } })
	H.eq(ok, true)
end)

H.test("studio reads: rigs, pose, selection, focus", function()
	local ok, rigs = run(claude, "studio.rigs", {})
	H.eq(ok, true, tostring(rigs))
	H.eq(#rigs, 1)
	H.eq(rigs[1].motors, 1)
	H.eq(rigs[1].humanoid, true)
	local ok2, pose = run(claude, "studio.pose", { target = "Workspace.Rig" })
	H.eq(ok2, true, tostring(pose))
	H.eq(pose.joints[1].name, "Neck")
	H.eq(pose.joints[1].c0.p[2], 1)
	local ok3, sel = run(claude, "studio.selection", {})
	H.eq(ok3, true)
	H.eq(sel[1]["$inst"][3], "Head")
	local ok4, focus = run(claude, "helper.focus", { targets = { "Workspace.Rig.Head" }, note = "checking the neck" })
	H.eq(ok4, true, tostring(focus))
	H.eq(touched[#touched].note, "checking the neck")
end)

H.test("saved animations are listed and read from AnimSaves", function()
	local saves = roblox.Instance.new("Folder")
	saves.Name = "AnimSaves"
	saves.Parent = rig
	local seq = roblox.Instance.new("KeyframeSequence")
	seq.Name = "Wave"
	seq.Parent = saves
	for i, t in { 0, 0.5 } do
		local k = roblox.Instance.new("Keyframe")
		k.Time = t
		k.Parent = seq
		local root = roblox.Instance.new("Pose")
		root.Name = "HumanoidRootPart"
		root.Parent = k
		local p = roblox.Instance.new("Pose")
		p.Name = "Head"
		p.CFrame = CFrame.new(0, i, 0)
		p.Parent = root
	end
	local ok, list = run(claude, "studio.animation", { target = "Workspace.Rig" })
	H.eq(ok, true, tostring(list))
	H.eq(list[1].name, "Wave")
	H.eq(list[1].keyframes, 2)
	local ok2, anim = run(claude, "studio.animation", { target = "Workspace.Rig", name = "Wave" })
	H.eq(ok2, true, tostring(anim))
	H.eq(anim.keyframes[2].time, 0.5)
	H.eq(anim.keyframes[2].poses[2].part, "Head")
	H.eq(anim.keyframes[2].poses[2].cframe.p[2], 2)
end)

H.test("errors come back clean and the runner never throws", function()
	local ok, err = run(claude, "studio.pose", { target = "Workspace.Missing" })
	H.eq(ok, false)
	H.eq(string.find(err, "No instance at Workspace.Missing") ~= nil, true, err)
	H.eq((run(claude, "nope.op", {})), false)
end)

H.test("Ownership: Kash's edits drop helper steps above the new count", function()
	local o = Ownership.new()
	Ownership.recordEdit(o, "a1", 1, 0)
	Ownership.recordEdit(o, "a1", 2, 0)
	H.eq(Ownership.observe(o, 2, 0), false)
	H.eq(Ownership.observe(o, 1, 1), true) -- Kash pressed Ctrl+Z on Claude's step
	H.eq(#o.undo, 1)
	H.eq((Ownership.canUndo(o, "a1", 1)), true)
	H.eq((Ownership.canRedo(o, "a1", 1)), false, "Kash's undo isn't Claude's to redo")
end)

H.finish()

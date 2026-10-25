--!strict
-- Runs one helper command inside Studio. Every edit goes through Eclipse's extension API, so it lands in the open
-- timeline right away and in Kash's undo history under the helper's name.

local Codec = require(script.Parent.Codec)
local Eclipse = require(script.Parent.Eclipse)
local Keybinds = require(script.Parent.Keybinds)
local Ownership = require(script.Parent.Ownership)

export type Agent = { id: string, name: string, color: string }
export type Command = { id: string, op: string, args: any, force: boolean?, agent: Agent }
export type Context = {
	root: Instance,
	coreGui: Instance?,
	ownership: Ownership.Ownership,
	selection: () -> { Instance },
	touch: (agent: Agent, targets: { Instance }, note: string, frame: number?) -> (),
	human: () -> any,
	live: (() -> any)?,
	busy: boolean,
}

local Commands = {}

local EDITS = {
	Add = true, AddObject = true, SetKeyframe = true, SetEasing = true, CreateFolder = true,
	RenameFolder = true, MoveToFolder = true, MoveToParent = true, Batch = true,
}
local UNDO_COMMANDS = { Undo = true, UndoAlternate = true, Redo = true, RedoAlternate = true, RedoShift = true }
local MAX_ROWS = 300

local function endpoint(ctx: Context): Eclipse.Endpoint
	local e = Eclipse.pick(ctx.coreGui)
	assert(e, "Eclipse Animator isn't open in this Studio window. Ask Kash to open Eclipse and an animation.")
	assert(
		e.version >= Eclipse.MinVersion,
		"This Eclipse Animator is too old for the helper (API v" .. e.version .. "); update Eclipse."
	)
	return e
end

local function call(e: Eclipse.Endpoint, action: string, request: any): any
	local ok, result = e.invoke(action, request or {})
	if not ok then
		error(result, 0)
	end
	return result
end

local function historyState(e: Eclipse.Endpoint): any?
	local ok, state = e.invoke("GetHistoryState", {})
	return if ok then state else nil
end

-- Let the watcher's view of history catch up before a helper acts, so Kash's own steps stay his.
local function observe(ctx: Context, e: Eclipse.Endpoint)
	local state = historyState(e)
	if state then
		Ownership.observe(ctx.ownership, state.UndoCount, state.RedoCount)
	end
end

local function claimNewSteps(ctx: Context, e: Eclipse.Endpoint, agent: Agent): any?
	local state = historyState(e)
	if state and state.UndoCount ~= ctx.ownership.undoCount then
		if state.UndoCount > ctx.ownership.undoCount then
			Ownership.recordEdit(ctx.ownership, agent.id, state.UndoCount, state.RedoCount)
		else
			Ownership.observe(ctx.ownership, state.UndoCount, state.RedoCount)
		end
	end
	return state
end

local function label(agent: Agent, text: string): string
	return string.sub(agent.name .. ": " .. text, 1, 100)
end

local function motorFor(part: Instance): Motor6D?
	if part:IsA("Motor6D") then
		return part -- ListTracks hands out the joint itself
	end
	local model: Instance? = part:FindFirstAncestorWhichIsA("Model") or part.Parent
	if not model then
		return nil
	end
	for _, d in (model :: Instance):GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 == part then
			return d
		end
	end
	return nil
end

-- Eclipse animates a clone of the rig (Camera.EclipseLivePreview.<rig>). A target on the real rig in Workspace maps
-- to the same instance in that clone, so "Workspace.Rig.Head" works as well as the path ListTracks returns.
local function toPreview(inst: Instance): Instance
	local camera = workspace.CurrentCamera
	local preview = camera and camera:FindFirstChild("EclipseLivePreview")
	if not preview or inst:IsDescendantOf(preview) then
		return inst
	end
	local path, node = {}, inst
	while node and node.Parent ~= workspace do
		table.insert(path, 1, node.Name)
		node = node.Parent :: Instance
	end
	if not node then
		return inst
	end
	local found: Instance? = preview:FindFirstChild(node.Name)
	for _, name in path do
		found = found and found:FindFirstChild(name)
	end
	return found or inst
end

local KEYED = { SetKeyframe = true, SetEasing = true }

local function remapTargets(action: string, request: any)
	if type(request) ~= "table" then
		return
	end
	if action == "Batch" and type(request.Actions) == "table" then
		for _, step in request.Actions do
			if type(step) == "table" and type(step.Action) == "string" then
				remapTargets(step.Action, step.Request)
			end
		end
		return
	end
	if not KEYED[action] then
		return
	end
	if typeof(request.Target) == "Instance" then
		request.Target = toPreview(request.Target)
	end
	if type(request.Targets) == "table" then
		for i, t in request.Targets do
			if typeof(t) == "Instance" then
				request.Targets[i] = toPreview(t)
			end
		end
	end
end

-- Offset = "bend from where the joint is now": Value = C0 * Offset on the joint that drives the target.
local function applyOffset(request: any)
	if type(request) ~= "table" or request.Offset == nil then
		return
	end
	assert(request.Value == nil, "Pass value or offset, not both")
	assert(typeof(request.Offset) == "CFrame", "offset must be a CFrame")
	assert(typeof(request.Target) == "Instance", "offset needs a target part")
	local motor = motorFor(request.Target)
	assert(motor, "offset needs a Motor6D joint driving " .. request.Target.Name .. "; pass value instead")
	request.Value = motor.C0 * request.Offset
	request.Offset = nil
end

local function targetsOf(request: any, out: { Instance })
	if type(request) ~= "table" then
		return
	end
	if typeof(request.Target) == "Instance" then
		table.insert(out, request.Target)
	end
	if type(request.Targets) == "table" then
		for _, t in request.Targets do
			if typeof(t) == "Instance" then
				table.insert(out, t)
			end
		end
	end
	if type(request.Actions) == "table" then
		for _, step in request.Actions do
			targetsOf(step.Request, out)
		end
	end
end

-- The frame an edit lands on (first batch step that has one), so Live can put the helper's playhead there.
local function frameOf(request: any): number?
	if type(request) ~= "table" then
		return nil
	end
	if type(request.Frame) == "number" then
		return request.Frame
	end
	if type(request.Actions) == "table" then
		for _, step in request.Actions do
			local f = if type(step) == "table" then frameOf(step.Request) else nil
			if f then
				return f
			end
		end
	end
	return nil
end

local function describe(action: string, request: any): string
	local t = type(request) == "table" and request.Target
	local name = if typeof(t) == "Instance" then " " .. t.Name else ""
	local frame = if type(request) == "table" and type(request.Frame) == "number" then " @" .. request.Frame else ""
	if action == "Batch" then
		local n = if type(request.Actions) == "table" then #request.Actions else 0
		return (if type(request.Name) == "string" then request.Name else "batch") .. " (" .. n .. " edits)"
	end
	return action .. name .. frame
end

local handlers: { [string]: (ctx: Context, cmd: Command) -> (any, string?, any?) } = {}

handlers["eclipse.invoke"] = function(ctx, cmd)
	local action = cmd.args.action
	assert(type(action) == "string", "action is required")
	assert(action ~= "Undo" and action ~= "Redo", "Use eclipse_history for undo and redo")
	assert(action ~= "BeginBatch" and action ~= "EndBatch", "Use the Batch action instead")
	local e = endpoint(ctx)
	local request = Codec.decode(cmd.args.request or {}, ctx.root)
	remapTargets(action, request)
	applyOffset(request)
	if action == "Batch" and type(request.Actions) == "table" then
		for _, step in request.Actions do
			applyOffset(step.Request)
		end
	end

	local targets = {}
	targetsOf(request, targets)
	local summary = describe(action, request)
	if #targets > 0 then
		ctx.touch(cmd.agent, targets, summary, frameOf(request))
	end

	if not EDITS[action] and action ~= "HistoryRecord" then
		return Codec.encode(call(e, action, request), ctx.root), summary
	end

	observe(ctx, e)
	local result
	if action == "Batch" then
		request.Name = label(cmd.agent, if type(request.Name) == "string" then request.Name else "batch")
		result = call(e, "Batch", request)
	elseif action == "HistoryRecord" then
		request.Name = label(cmd.agent, if type(request.Name) == "string" then request.Name else "edit")
		result = call(e, action, request)
	elseif request.Record == false then
		-- Pending edits stay unrecorded until the helper calls HistoryRecord or RevertChanges.
		result = call(e, action, request)
	else
		-- A one-step batch gives the edit the helper's name in Kash's undo history.
		local wrapped = call(e, "Batch", {
			Name = label(cmd.agent, summary),
			Actions = { { Action = action, Request = request } },
		})
		result = wrapped.Results[1]
	end
	local state = claimNewSteps(ctx, e, cmd.agent)
	return Codec.encode(result, ctx.root), summary, state
end

handlers["eclipse.command"] = function(ctx, cmd)
	local args = cmd.args
	local e = endpoint(ctx)
	local key, modifiers = args.key, args.modifiers
	if not key then
		assert(type(args.command) == "string", "command or key is required")
		assert(not UNDO_COMMANDS[args.command], "Use eclipse_history for undo and redo")
		local binding = Keybinds[args.command]
		assert(binding, "Unknown Eclipse command " .. tostring(args.command))
		key, modifiers = binding.Key, binding.Modifiers
	end
	local times = math.clamp(math.floor(tonumber(args["repeat"]) or 1), 1, 120)
	observe(ctx, e)
	local handled = 0
	for _ = 1, times do
		local result = call(e, "ForwardInput", { Key = key, Modifiers = modifiers or {} })
		if result.Handled then
			handled += 1
		end
	end
	local state = claimNewSteps(ctx, e, cmd.agent)
	local summary = (args.command or key) .. (if times > 1 then " x" .. times else "")
	return { Handled = handled > 0, Presses = times, HandledCount = handled }, summary, state
end

handlers["eclipse.history"] = function(ctx, cmd)
	local e = endpoint(ctx)
	observe(ctx, e)
	local op = cmd.args.op
	local o = ctx.ownership
	if op == "state" or op == nil then
		local state = call(e, "GetHistoryState", {})
		local mine = 0
		for _, step in o.undo do
			if step.agent == cmd.agent.id then
				mine += 1
			end
		end
		state.YourUndoSteps = mine
		state.NewestStepIsYours = Ownership.canUndo(o, cmd.agent.id, state.UndoCount)
		return state, "history"
	end
	local state = call(e, "GetHistoryState", {})
	if op == "undo" then
		if not cmd.force then
			local ok, why = Ownership.canUndo(o, cmd.agent.id, state.UndoCount)
			assert(ok, why)
		end
		local result = call(e, "Undo", {})
		Ownership.didUndo(o, cmd.agent.id, result.UndoCount, result.RedoCount)
		return result, "undo"
	elseif op == "redo" then
		if not cmd.force then
			local ok, why = Ownership.canRedo(o, cmd.agent.id, state.RedoCount)
			assert(ok, why)
		end
		local result = call(e, "Redo", {})
		Ownership.didRedo(o, cmd.agent.id, result.UndoCount, result.RedoCount)
		return result, "redo"
	end
	error("op must be state, undo or redo", 0)
end

handlers["eclipse.status"] = function(ctx, _cmd)
	local sessions = Eclipse.sessions(ctx.coreGui)
	local out: any = {
		place = game.Name,
		eclipse = { found = #sessions > 0, sessions = {} },
		human = ctx.human(),
		live = if ctx.live then ctx.live() else nil,
	}
	for _, s in sessions do
		table.insert(out.eclipse.sessions, { session = s.session, version = s.version })
	end
	local e = Eclipse.pick(ctx.coreGui)
	if e then
		local ok, info = e.invoke("GetInfo", {})
		out.eclipse.info = if ok then info else nil
		if ok and info.Active then
			local okFrame, frame = e.invoke("GetCurrentFrame", {})
			out.eclipse.frame = if okFrame then frame else nil
			out.eclipse.history = historyState(e)
		else
			out.eclipse.note = "Eclipse is installed but no animation is open; ask Kash to open one."
		end
		if e.version < Eclipse.MinVersion then
			out.eclipse.note = "Eclipse API v" .. e.version .. " is older than v" .. Eclipse.MinVersion .. "; update Eclipse."
		end
	else
		out.eclipse.note = "Eclipse Animator isn't open (its API folder is missing from CoreGui)."
	end
	return Codec.encode(out, ctx.root), "status"
end

local function isRig(model: Instance): boolean
	return model:FindFirstChildWhichIsA("Humanoid") ~= nil
		or model:FindFirstChildWhichIsA("AnimationController") ~= nil
		or model:FindFirstChild("AnimSaves") ~= nil
end

local function savesOf(model: Instance): Instance?
	local saves = model:FindFirstChild("AnimSaves")
	if saves and saves:IsA("ObjectValue") then
		return saves.Value
	end
	return saves
end

handlers["studio.rigs"] = function(ctx, _cmd)
	-- Lists with table.find rather than instance-keyed tables, so this also runs under Lune in the tests.
	local onTimeline: { Instance } = {}
	local e = Eclipse.pick(ctx.coreGui)
	if e then
		local ok, rows = e.invoke("ListTracks", {})
		if ok then
			for _, row in rows do
				if typeof(row.Rig) == "Instance" and not table.find(onTimeline, row.Rig) then
					table.insert(onTimeline, row.Rig)
				end
			end
		end
	end
	local rigs = {}
	local seen: { Instance } = {}
	for _, d in workspace:GetDescendants() do
		local model = if d:IsA("Motor6D") then d:FindFirstAncestorWhichIsA("Model") elseif d:IsA("Model") and isRig(d) then d else nil
		if model and not table.find(seen, model) then
			table.insert(seen, model)
			local motors, bones = 0, 0
			for _, x in model:GetDescendants() do
				if x:IsA("Motor6D") then
					motors += 1
				elseif x:IsA("Bone") then
					bones += 1
				end
			end
			local saves = savesOf(model)
			table.insert(rigs, {
				rig = model,
				motors = motors,
				bones = bones,
				humanoid = model:FindFirstChildWhichIsA("Humanoid") ~= nil,
				savedAnimations = if saves then #saves:GetChildren() else 0,
				onTimeline = table.find(onTimeline, model) ~= nil,
			})
			if #rigs >= 200 then
				break
			end
		end
	end
	return Codec.encode(rigs, ctx.root), "found " .. #rigs .. " rigs"
end

handlers["studio.pose"] = function(ctx, cmd)
	local target = Codec.resolveInstance(cmd.args.target, ctx.root)
	local joints, bones = {}, {}
	for _, d in target:GetDescendants() do
		if d:IsA("Motor6D") and #joints < MAX_ROWS then
			table.insert(joints, {
				joint = d, name = d.Name, part0 = d.Part0, part1 = d.Part1,
				c0 = d.C0, c1 = d.C1, transform = d.Transform,
			})
		elseif d:IsA("Bone") and #bones < MAX_ROWS then
			table.insert(bones, { bone = d, name = d.Name, cframe = d.CFrame, transform = d.Transform })
		end
	end
	ctx.touch(cmd.agent, { target }, "reading pose")
	return Codec.encode({ target = target, joints = joints, bones = bones }, ctx.root), "read pose of " .. target.Name
end

local function readPoses(pose: Instance, out: { any })
	for _, p in pose:GetChildren() do
		if p:IsA("Pose") then
			table.insert(out, {
				part = p.Name, cframe = p.CFrame, weight = p.Weight,
				easingStyle = p.EasingStyle, easingDirection = p.EasingDirection,
			})
			readPoses(p, out)
		end
	end
end

handlers["studio.animation"] = function(ctx, cmd)
	local target = Codec.resolveInstance(cmd.args.target, ctx.root)
	local saves = savesOf(target)
	assert(saves, target.Name .. " has no AnimSaves yet (Eclipse creates it when you save or export)")
	if not cmd.args.name then
		local list = {}
		for _, s in saves:GetChildren() do
			local entry: any = { name = s.Name, class = s.ClassName }
			if s:IsA("KeyframeSequence") then
				local length, count = 0, 0
				for _, k in s:GetChildren() do
					if k:IsA("Keyframe") then
						count += 1
						length = math.max(length, k.Time)
					end
				end
				entry.keyframes, entry.length, entry.loop, entry.priority = count, length, s.Loop, s.Priority
			end
			table.insert(list, entry)
		end
		return Codec.encode(list, ctx.root), "listed animations"
	end
	local seq = saves:FindFirstChild(cmd.args.name)
	assert(seq and seq:IsA("KeyframeSequence"), "No saved animation named " .. tostring(cmd.args.name))
	local keyframes = {}
	for _, k in seq:GetChildren() do
		if k:IsA("Keyframe") then
			local poses = {}
			readPoses(k, poses)
			table.insert(keyframes, { time = k.Time, name = k.Name, poses = poses })
		end
	end
	table.sort(keyframes, function(a, b)
		return a.time < b.time
	end)
	while #keyframes > MAX_ROWS do
		table.remove(keyframes)
	end
	local out = { name = seq.Name, loop = seq.Loop, priority = seq.Priority, keyframes = keyframes }
	return Codec.encode(out, ctx.root), "read " .. seq.Name
end

handlers["studio.selection"] = function(ctx, _cmd)
	return Codec.encode(ctx.selection(), ctx.root), "looked at Kash's selection"
end

handlers["helper.focus"] = function(ctx, cmd)
	local targets = {}
	for _, t in cmd.args.targets or {} do
		table.insert(targets, Codec.resolveInstance(t, ctx.root))
	end
	assert(#targets > 0, "targets is empty")
	local note = string.sub(tostring(cmd.args.note or "looking"), 1, 80)
	ctx.touch(cmd.agent, targets, note, tonumber(cmd.args.frame))
	return { focused = #targets }, note
end

-- Returns ok, result-or-error, summary, history state (when it changed).
function Commands.run(ctx: Context, cmd: Command): (boolean, any, string?, any?)
	local handler = handlers[cmd.op]
	if not handler then
		return false, "Unknown op " .. tostring(cmd.op), nil, nil
	end
	ctx.busy = true
	local ok, result, summary, state = pcall(handler, ctx, cmd)
	ctx.busy = false
	if not ok then
		return false, (string.gsub(tostring(result), "^.-:%d+: ", "")), nil, nil
	end
	return true, result, summary, state
end

Commands.handlers = handlers

return Commands

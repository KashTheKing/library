--!nocheck
--[[
	Lune test harness for Stagger. It builds a small virtual Roblox: two peers (server and client)
	loading their own copies of the modules, a fake Packet that delivers across them, a virtual clock
	for task.delay, RunService signals fired by hand, Humanoid methods and events implemented through
	Lune's implementMethod / implementProperty, and a synthetic R15 Avatar Joint Upgrade rig. The
	scenarios then drive whole staggers end to end and check joints, tags, attributes, Humanoid
	settings, signals and packets.

	Three Lune limitations are worked around at load time and nowhere else: Players.LocalPlayer,
	Humanoid.FloorMaterial and BasePart.Position have no overridable defaults in Lune's reflection
	database, so those reads are redirected to harness hooks (see requireFor).
]]
local roblox = require("@lune/roblox")
local luau = require("@lune/luau")
local fs = require("@lune/fs")
local realTask = require("@lune/task")

-- Run from the repository root: lune-tests/run.sh (fetches Trove and Signal into vendor/ first).
local process = require("@lune/process")
local ROOT = process.cwd
local SRC = ROOT .. "/packages/src"
local HERE = SRC .. "/Stagger/lune-tests"
local VENDOR = HERE .. "/vendor"

--------------------------------------------------------------------------------------------------
-- Tiny signal used for the virtual engine events
--------------------------------------------------------------------------------------------------
local Sig = {}
Sig.__index = Sig
function Sig.new() return setmetatable({ _h = {} }, Sig) end
function Sig:Connect(fn)
	local h = { fn = fn, Connected = true }
	table.insert(self._h, h)
	return { Disconnect = function() h.Connected = false end, Connected = true }
end
function Sig:Once(fn)
	local c; c = self:Connect(function(...) c:Disconnect(); fn(...) end); return c
end
function Sig:Fire(...)
	for _, h in table.clone(self._h) do
		if h.Connected then h.fn(...) end
	end
	local keep = {}
	for _, h in self._h do if h.Connected then table.insert(keep, h) end end
	self._h = keep
end

--------------------------------------------------------------------------------------------------
-- Virtual clock + task
--------------------------------------------------------------------------------------------------
local Clock = { now = 0, delays = {} }
local taskShim = setmetatable({}, { __index = realTask })
function taskShim.delay(seconds, fn, ...)
	local args = table.pack(...)
	local co = coroutine.create(function() fn(table.unpack(args, 1, args.n)) end)
	table.insert(Clock.delays, { at = Clock.now + seconds, co = co })
	return co
end
function taskShim.cancel(co)
	for i, d in Clock.delays do if d.co == co then table.remove(Clock.delays, i); return end end
	pcall(realTask.cancel, co)
end
function taskShim.spawn(fn, ...)
	if typeof(fn) == "thread" then
		for i, d in Clock.delays do if d.co == fn then table.remove(Clock.delays, i) end end
		local ok, err = coroutine.resume(fn, ...); if not ok then error(err) end
		return fn
	end
	local co = coroutine.create(fn)
	local ok, err = coroutine.resume(co, ...); if not ok then error(err) end
	return co
end
taskShim.defer = taskShim.spawn
function Clock.advance(dt)
	Clock.now += dt
	local due = {}
	for i = #Clock.delays, 1, -1 do
		if Clock.delays[i].at <= Clock.now then table.insert(due, 1, table.remove(Clock.delays, i)) end
	end
	table.sort(due, function(a, b) return a.at < b.at end)
	for _, d in due do local ok, err = coroutine.resume(d.co); if not ok then error(err) end end
end

--------------------------------------------------------------------------------------------------
-- Random shim (Lune has no Random)
--------------------------------------------------------------------------------------------------
local RandomShim = {}
RandomShim.__index = RandomShim
function RandomShim.new(seed)
	-- xorshift so both peers and both runs agree
	return setmetatable({ s = (seed or 0) * 2654435761 % 4294967296 + 1 }, RandomShim)
end
function RandomShim:_next()
	local x = self.s
	x = bit32.bxor(x, bit32.lshift(x, 13)); x = bit32.bxor(x, bit32.rshift(x, 17)); x = bit32.bxor(x, bit32.lshift(x, 5))
	self.s = x
	return x / 4294967296
end
function RandomShim:NextNumber(a, b) local r = self:_next(); if a then return a + r * (b - a) end return r end
function RandomShim:NextInteger(a, b) return math.floor(self:NextNumber(a, b + 1)) end

--------------------------------------------------------------------------------------------------
-- Virtual engine: Humanoid methods/events, part velocities, model events
--------------------------------------------------------------------------------------------------
local perInstance = setmetatable({}, { __mode = "k" })
local function store(inst) local t = perInstance[inst]; if not t then t = { states = {}, floor = roblox.Enum.Material.Plastic, moves = {}, changes = {} }; perInstance[inst] = t end return t end
local function sigProp(class, name)
	roblox.implementProperty(class, name, function(self) local s = store(self); s[name] = s[name] or Sig.new(); return s[name] end, function() end)
end
-- Network ownership: record who owns each part so tests can check NPCs stay on the server.
roblox.implementMethod("BasePart", "CanSetNetworkOwnership", function(self) return not self.Anchored end)
roblox.implementMethod("BasePart", "SetNetworkOwner", function(self, owner) store(self).owner = owner or "server" end)
roblox.implementMethod("Humanoid", "GetStateEnabled", function(self, state) local v = store(self).states[tostring(state)]; if v == nil then return true end return v end)
roblox.implementMethod("Humanoid", "SetStateEnabled", function(self, state, enabled) store(self).states[tostring(state)] = enabled end)
roblox.implementMethod("Humanoid", "Move", function(self, dir, rel) local s = store(self); s.moveDirection = dir; table.insert(s.moves, dir) end)
roblox.implementMethod("Humanoid", "ChangeState", function(self, state) local s = store(self); s.state = state; table.insert(s.changes, state) end)
roblox.implementMethod("Humanoid", "GetState", function(self) return store(self).state or roblox.Enum.HumanoidStateType.Running end)
roblox.implementProperty("Humanoid", "RootPart", function(self) return self.Parent and self.Parent:FindFirstChild("HumanoidRootPart") end, function() end)
roblox.implementProperty("Humanoid", "FloorMaterial", function(self) return store(self).floor end, function(self, v) store(self).floor = v end)
roblox.implementProperty("Humanoid", "MoveDirection", function(self) return store(self).moveDirection or roblox.Vector3.zero end, function() end)
sigProp("Humanoid", "Died")
sigProp("Humanoid", "StateChanged")
sigProp("Model", "AncestryChanged")
for _, class in { "Part", "MeshPart" } do
	roblox.implementProperty(class, "Position", function(self) return self.CFrame.Position end, function(self, v) self.CFrame = roblox.CFrame.new(v) end)
	roblox.implementProperty(class, "AssemblyLinearVelocity", function(self) return store(self).lv or roblox.Vector3.zero end, function(self, v) store(self).lv = v end)
	roblox.implementProperty(class, "AssemblyAngularVelocity", function(self) return store(self).av or roblox.Vector3.zero end, function(self, v) store(self).av = v end)
end

--------------------------------------------------------------------------------------------------
-- Game tree + per-peer services
--------------------------------------------------------------------------------------------------
local game = roblox.Instance.new("DataModel")
local workspaceFolder = roblox.Instance.new("Folder"); workspaceFolder.Name = "Workspace"; workspaceFolder.Parent = game
-- Raycasts hit a floor just under where they start, unless a test says the character is in the air.
local AIRBORNE = false
roblox.implementMethod("Folder", "Raycast", function(_, origin)
	if AIRBORNE then return nil end
	return { Position = roblox.Vector3.new(origin.X, origin.Y - 3, origin.Z) }
end)
local packages = roblox.Instance.new("Folder"); packages.Name = "Packages"; packages.Parent = game

local localPlayer = { Name = "Kash", Character = nil, ClassName = "Player" }
local players = { [localPlayer] = true }
local BRIDGE = { log = {}, localPlayer = localPlayer }

local peers = {}
local function makePeer(side)
	local isServer = side == "server"
	local peer = {
		side = side,
		RunService = { IsServer = function() return isServer end, IsClient = function() return not isServer end, IsStudio = function() return true end,
			Heartbeat = Sig.new(), PreSimulation = Sig.new(), PostSimulation = Sig.new(), RenderStepped = Sig.new(), Stepped = Sig.new() },
		Players = { LocalPlayer = if isServer then nil else localPlayer, PlayerAdded = Sig.new(), PlayerRemoving = Sig.new(),
			GetPlayerFromCharacter = function(_, character) for p in players do if p.Character == character then return p end end return nil end,
			GetPlayers = function() local t = {} for p in players do table.insert(t, p) end return t end },
		CollectionService = { GetInstanceAddedSignal = function() return Sig.new() end, GetInstanceRemovedSignal = function() return Sig.new() end, GetTagged = function() return {} end },
		cache = {},
		warnings = {},
	}
	peers[side] = peer
	return peer
end
makePeer("server"); makePeer("client")
local CURRENT = "server"
BRIDGE.setCurrent = function(side) local prev = CURRENT; CURRENT = side; return prev end
local function cur() return peers[CURRENT] end
roblox.implementMethod("RunService", "IsServer", function() return cur().RunService.IsServer() end)
roblox.implementMethod("RunService", "IsClient", function() return cur().RunService.IsClient() end)
roblox.implementMethod("RunService", "IsStudio", function() return true end)
for _, ev in { "Heartbeat", "PreSimulation", "PostSimulation", "RenderStepped", "Stepped" } do
	roblox.implementProperty("RunService", ev, function() return cur().RunService[ev] end, function() end)
end
roblox.implementProperty("Players", "LocalPlayer", function() return cur().Players.LocalPlayer end, function() end)
roblox.implementProperty("Players", "PlayerAdded", function() return cur().Players.PlayerAdded end, function() end)
roblox.implementProperty("Players", "PlayerRemoving", function() return cur().Players.PlayerRemoving end, function() end)
roblox.implementMethod("Players", "GetPlayerFromCharacter", function(_, c) return cur().Players.GetPlayerFromCharacter(nil, c) end)
roblox.implementMethod("Players", "GetPlayers", function() return cur().Players.GetPlayers() end)
roblox.implementMethod("CollectionService", "GetInstanceAddedSignal", function() return Sig.new() end)
roblox.implementMethod("CollectionService", "GetInstanceRemovedSignal", function() return Sig.new() end)
roblox.implementMethod("CollectionService", "GetTagged", function() return {} end)

--------------------------------------------------------------------------------------------------
-- Module tree and per-peer require
--------------------------------------------------------------------------------------------------
local sources = {} -- ModuleScript -> path
local function module(name, path, parent)
	local ms = roblox.Instance.new("ModuleScript"); ms.Name = name; ms.Parent = parent; sources[ms] = path; return ms
end
local stagger = module("Stagger", SRC .. "/Stagger/init.luau", packages)
for _, n in { "Balance", "Config", "Controller", "Packets", "Rig" } do module(n, SRC .. "/Stagger/" .. n .. ".luau", stagger) end
module("Packet", HERE .. "/FakePacket.luau", packages)
module("Binder", SRC .. "/Binder/init.luau", packages)
module("Trove", VENDOR .. "/Trove.luau", packages)
module("Signal", VENDOR .. "/Signal.luau", packages)
local predicates = roblox.Instance.new("ModuleScript"); predicates.Name = "Predicates"; predicates.Parent = packages
sources[predicates] = false

local function requireFor(side)
	local peer = peers[side]
	local function req(ms)
		if typeof(ms) == "string" then return require(ms) end
		if peer.cache[ms] ~= nil then return peer.cache[ms] end
		local path = sources[ms]
		if path == false then peer.cache[ms] = {}; return {} end
		assert(path, "unknown module " .. tostring(ms))
		local src = fs.readFile(path)
		-- Lune's built-in Players.LocalPlayer / Humanoid.FloorMaterial cannot be overridden, so
		-- these two reads are routed to harness hooks. Nothing else in the sources is touched.
		src = src:gsub("Players%.LocalPlayer", "__H.localPlayer()"):gsub("humanoid%.FloorMaterial", "__H.floor(humanoid)")
		if path:find("/Stagger/") then src = src:gsub("torso%.Position", "torso.CFrame.Position") end -- BasePart.Position has no Lune default
		-- Transform is local to each peer in Roblox (it never replicates), but the peers here share
		-- instances, so keep one Transform per peer.
		if path:find("/Stagger/") then
			src = src:gsub("joint%.Transform = ([^\n]+)", "__H.setTransform(joint, %1)"):gsub("joint%.Transform", "__H.transform(joint)")
			-- Script.Enabled has no Lune default either.
			src = src:gsub("animate%.Enabled = ([^\n]+)", "__H.setEnabled(animate, %1)"):gsub("animate%.Enabled", "__H.enabled(animate)")
			-- Nor does BasePart.AssemblyLinearVelocity.
			src = src:gsub("root%.AssemblyLinearVelocity = ([^\n]+)", "__H.setVelocity(root, %1)"):gsub("root%.AssemblyLinearVelocity", "__H.velocity(root)")
		end
		local env = setmetatable({
			__H = { localPlayer = function() return cur().Players.LocalPlayer end, floor = function(h) return store(h).floor end,
				transform = function(j) return store(j)["transform_" .. CURRENT] or roblox.CFrame.identity end,
				setTransform = function(j, v) store(j)["transform_" .. CURRENT] = v end,
				enabled = function(x) local v = store(x).enabled; if v == nil then return true end return v end,
				setEnabled = function(x, v) store(x).enabled = v end,
				velocity = function(p) return store(p).lv or roblox.Vector3.zero end,
				setVelocity = function(p, v) store(p).lv = v end },
			script = ms, game = game, workspace = workspaceFolder,
			Enum = roblox.Enum, Vector3 = roblox.Vector3, CFrame = roblox.CFrame, Random = RandomShim, Instance = roblox.Instance,
			RaycastParams = { new = function() return {} end },
			task = taskShim, require = nil, _G_BRIDGE = BRIDGE,
			warn = function(...) table.insert(peer.warnings, table.concat({ ... }, " ")) end,
		}, { __index = function(_, k) return (getfenv(0))[k] end })
		env.require = req
		local prev = CURRENT; CURRENT = side
		local fn = luau.load(src, { debugName = side .. ":" .. ms.Name, environment = env })
		local result = fn()
		CURRENT = prev
		peer.cache[ms] = result
		return result
	end
	return req
end

--------------------------------------------------------------------------------------------------
-- Synthetic R15 Avatar Joint Upgrade rig
--------------------------------------------------------------------------------------------------
local JOINTS = {
	{ "Root", "HumanoidRootPart", "LowerTorso" }, { "Waist", "LowerTorso", "UpperTorso" }, { "Neck", "UpperTorso", "Head" },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm" }, { "LeftElbow", "LeftUpperArm", "LeftLowerArm" }, { "LeftWrist", "LeftLowerArm", "LeftHand" },
	{ "RightShoulder", "UpperTorso", "RightUpperArm" }, { "RightElbow", "RightUpperArm", "RightLowerArm" }, { "RightWrist", "RightLowerArm", "RightHand" },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg" }, { "LeftKnee", "LeftUpperLeg", "LeftLowerLeg" }, { "LeftAnkle", "LeftLowerLeg", "LeftFoot" },
	{ "RightHip", "LowerTorso", "RightUpperLeg" }, { "RightKnee", "RightUpperLeg", "RightLowerLeg" }, { "RightAnkle", "RightLowerLeg", "RightFoot" },
}
local function buildCharacter(name, legacy)
	local model = roblox.Instance.new("Model"); model.Name = name
	local parts = {}
	local function part(n, cf)
		local p = roblox.Instance.new("Part"); p.Name = n; p.CFrame = cf or roblox.CFrame.new(0, 3, 0); p.CanCollide = (n == "HumanoidRootPart"); p.Parent = model; parts[n] = p; return p
	end
	part("HumanoidRootPart", roblox.CFrame.new(0, 3, 0)); part("LowerTorso", roblox.CFrame.new(0, 3, 0)); part("UpperTorso", roblox.CFrame.new(0, 4, 0)); part("Head", roblox.CFrame.new(0, 5, 0))
	for _, j in JOINTS do if not parts[j[3]] then part(j[3]) end end
	for _, j in JOINTS do
		local a0 = roblox.Instance.new("Attachment"); a0.Name = j[1] .. "RigAttachment"; a0.Parent = parts[j[2]]
		local a1 = roblox.Instance.new("Attachment"); a1.Name = j[1] .. "RigAttachment"; a1.Parent = parts[j[3]]
		if legacy then
			local m = roblox.Instance.new("Motor6D"); m.Name = j[1]; m.Part0 = parts[j[2]]; m.Part1 = parts[j[3]]; m.Parent = parts[j[3]]
		else
			local ac = roblox.Instance.new("AnimationConstraint"); ac.Name = j[1]; ac.Attachment0 = a0; ac.Attachment1 = a1; ac.IsKinematic = true; ac.Parent = parts[j[3]] -- Roblox default is true; Lune's reflection default is false
			if j[1] ~= "Root" then
				local bs = roblox.Instance.new("BallSocketConstraint"); bs.Name = j[1] .. "BallSocket"; bs.Attachment0 = a0; bs.Attachment1 = a1; bs.Enabled = false; bs.LimitsEnabled = true; bs.Parent = parts[j[3]]
			end
		end
	end
	local hum = roblox.Instance.new("Humanoid"); hum.RigType = roblox.Enum.HumanoidRigType.R15; hum.WalkSpeed = 16; hum.Health = 100; hum.Parent = model
	model.Parent = workspaceFolder
	return model, hum, parts
end

--------------------------------------------------------------------------------------------------
-- Load both peers
--------------------------------------------------------------------------------------------------
local Server = requireFor("server")(stagger)
local Client = requireFor("client")(stagger)
assert(Server ~= Client, "peers must have separate module instances")

local function frame(dt)
	dt = dt or 1 / 60
	for _, side in { "server", "client" } do
		CURRENT = side
		peers[side].RunService.PreSimulation:Fire(dt)
	end
	for _, side in { "server", "client" } do
		CURRENT = side
		peers[side].RunService.Heartbeat:Fire(dt)
	end
	CURRENT = "server"
	Clock.advance(dt)
end
local function run(seconds, untilFn)
	local t = 0
	while t < seconds do
		frame(1 / 60); t += 1 / 60
		if untilFn and untilFn() then return t end
	end
	return t
end

--------------------------------------------------------------------------------------------------
-- Test helpers
--------------------------------------------------------------------------------------------------
local passed, failed = 0, 0
local function check(cond, msg)
	if cond then passed += 1 else failed += 1; print("  FAIL: " .. msg) end
end
local function peerTransform(j, side) return store(j)["transform_" .. side] or roblox.CFrame.identity end
local function jointsOf(model)
	local t = {}
	for _, d in model:GetDescendants() do if d:IsA("AnimationConstraint") then t[d.Name] = d end end
	return t
end
local function socketsOf(model)
	local t = {}
	for _, d in model:GetDescendants() do if d:IsA("BallSocketConstraint") then table.insert(t, d) end end
	return t
end
local function allKinematic(model)
	for _, j in jointsOf(model) do if not j.IsKinematic then return false end end
	return true
end
local S = Server.State
local function scenario(name, fn)
	print("\n== " .. name)
	local before = failed
	CURRENT = "server"
	local ok, err = pcall(fn)
	if not ok then failed += 1; print("  ERROR: " .. tostring(err)) end
	print(if failed == before then "  ok" else "  FAILED")
end

--------------------------------------------------------------------------------------------------
-- Scenarios
--------------------------------------------------------------------------------------------------
scenario("API surface", function()
	for _, k in { "Begin", "Ragdoll", "Recover", "Stop", "GetState", "IsStaggering", "GetController", "GetCharacters", "RegisterPreset", "IsSupported" } do
		check(typeof(Server[k]) == "function", "Stagger." .. k .. " exists")
	end
	check(Server.State.Idle == 0 and Server.State.Ragdoll == 2, "state enum")
	check(Server.Presets.Default and Server.Presets.Heavy and Server.Presets.Drunk, "presets")
	check(pcall(Server.RegisterPreset, "Custom", Server.Presets.Default, { MisstepChance = 0.9 }), "register preset")
	check(not pcall(Server.RegisterPreset, "Bad", Server.Presets.Default, { Nope = 1 }), "unknown key rejected")
	check(not pcall(Server.RegisterPreset, "Bad2", Server.Presets.Default, { MaxLean = "x" }), "wrong type rejected")
	check(Client.RegisterPreset("Custom", Client.Presets.Default, { MisstepChance = 0.9 }) ~= nil, "client preset")
	check(#peers.server.warnings == 0 and #peers.client.warnings == 0, "no warnings on load")
end)

scenario("Legacy Motor6D rig is skipped", function()
	local model = buildCharacter("Legacy", true)
	check(Server.IsSupported(model) == false, "not supported")
	check(Server.Begin(model, roblox.Vector3.xAxis) == false, "Begin returns false")
	check(#peers.server.warnings == 1 and peers.server.warnings[1]:find("AnimationConstraint") ~= nil, "warned once")
	check(Server.Begin(model, roblox.Vector3.xAxis) == false and #peers.server.warnings == 1, "warns only once")
	model:Destroy()
end)

local function playerCharacter(name)
	local model, hum, parts = buildCharacter(name)
	localPlayer.Character = model
	return model, hum, parts
end

scenario("Player character: stagger, client drives, recovers, everything restored", function()
	local model, hum, parts = playerCharacter("Kash")
	local joints = jointsOf(model)
	local original = {}
	for n, j in joints do original[n] = { j.IsKinematic, j.AngularStrength, j.AngularDamping } end

	local states = {}
	local conn = Client.StateChanged:Connect(function(c, s, prev) table.insert(states, s) end)

	local animate = roblox.Instance.new("LocalScript"); animate.Name = "Animate"; animate.Parent = model
	local ok = Server.Begin(model, roblox.Vector3.new(1, 0, 0), { Preset = "Light", Intensity = 1, Seed = 7 })
	check(ok == true, "Begin ok")
	check(Server.GetState(model) == S.Staggering, "server Staggering")
	check(Client.GetState(model) == S.Staggering, "client Staggering via packet")
	check(store(animate).enabled == false, "Animate paused while staggering")
	check((store(parts.HumanoidRootPart).lv or roblox.Vector3.zero).Magnitude > 1, "body shoved on the frame of the hit")
	check(model:HasTag("Staggering"), "tag added")
	check(model:GetAttribute("StaggerState") == S.Staggering, "attribute set")
	check(#BRIDGE.log >= 1 and BRIDGE.log[#BRIDGE.log].name == "Stagger.State", "state packet sent")

	-- Muscle mode: upper simulated, lower kinematic, sockets on
	for _, n in { "Waist", "Neck", "LeftShoulder", "RightElbow" } do check(joints[n].IsKinematic == false, n .. " simulated") check(math.abs(joints[n].AngularStrength - 0.3) < 1e-6, n .. " muscle strength") end
	for _, n in { "Root", "LeftHip", "RightKnee", "LeftAnkle" } do check(joints[n].IsKinematic == true, n .. " kinematic") end
	for _, s in socketsOf(model) do check(s.Enabled and s.LimitsEnabled, "socket enabled") end
	check(hum.AutoRotate == false, "AutoRotate off")

	local cc = Client.GetController(model)
	local sc = Server.GetController(model)
	check(cc and cc.IsDriver == true, "client is driver")
	check(sc and sc.IsDriver == false, "server is not driver")
	check(cc.Balance ~= nil and sc.Balance == nil, "only driver has a Balance")
	check(hum:GetStateEnabled(roblox.Enum.HumanoidStateType.Jumping) == false, "jumping disabled")

	-- Run a few frames: pose written, humanoid moved
	run(0.5)
	local hs = store(hum)
	check(#hs.moves > 0, "Humanoid:Move called")
	local moved = false
	for _, m in hs.moves do if m.Magnitude > 0 then moved = true end end
	check(moved, "moved forward in steps")
	check(hum.WalkSpeed ~= 16, "WalkSpeed changed while staggering")
	check(peerTransform(joints.Root, "client") ~= roblox.CFrame.identity or peerTransform(joints.Waist, "client") ~= roblox.CFrame.identity, "procedural pose applied")
	check(Server.GetState(model) == S.Staggering, "still staggering after 0.5s")

	local t = run(10, function() return Server.GetState(model) ~= S.Staggering end)
	local outcome = Server.GetState(model)
	print(string.format("  outcome after %.2fs: %s", t, Server.StateNames[outcome]))
	check(outcome == S.Recovering or outcome == S.Ragdoll, "decided")
	local reported = false
	for _, e in BRIDGE.log do if e.name == "Stagger.Report" then reported = true end end
	check(reported, "client reported outcome via packet")

	run(10, function() return Server.GetState(model) == S.Idle end)
	check(Server.GetState(model) == S.Idle and Client.GetState(model) == S.Idle, "back to Idle on both peers")
	check(store(animate).enabled == true, "Animate running again")
	check(not model:HasTag("Staggering"), "tag removed")
	check(model:GetAttribute("StaggerState") == nil, "attribute cleared")
	for n, j in joints do
		check(j.IsKinematic == original[n][1] and j.AngularStrength == original[n][2] and j.AngularDamping == original[n][3], n .. " restored")
	end
	for _, s in socketsOf(model) do check(s.Enabled == false and s.LimitsEnabled == true, "socket restored") end
	check(hum.WalkSpeed == 16, "WalkSpeed restored on driver")
	check(hum.AutoRotate == true, "AutoRotate restored")
	check(hum:GetStateEnabled(roblox.Enum.HumanoidStateType.Jumping) == true, "jumping restored")
	check(hum:GetStateEnabled(roblox.Enum.HumanoidStateType.GettingUp) == true, "GettingUp restored")
	check(parts.HumanoidRootPart.CanCollide == true, "root collision restored")
	check(hs.moveDirection.Magnitude == 0, "stopped moving")
	check(#Server.GetCharacters() == 0 and #Client.GetCharacters() == 0, "no bound characters")
	check(states[1] == S.Staggering and states[#states] == S.Idle, "client signals fired in order")
	conn:Disconnect()
	model:Destroy(); localPlayer.Character = nil
end)

scenario("Player character: heavy hit falls, ragdolls, auto gets up", function()
	local model, hum, parts = playerCharacter("Kash")
	local joints = jointsOf(model)
	local fell = 0
	local c1 = Server.Fell:Connect(function() fell += 1 end)
	local recoveredSignal = 0
	local c2 = Server.Recovered:Connect(function() recoveredSignal += 1 end)

	Server.Begin(model, roblox.Vector3.new(0, 0, -1), { Preset = "Heavy", Intensity = 2, Seed = 3 })
	local t = run(10, function() return Server.GetState(model) ~= S.Staggering end)
	print(string.format("  decided after %.2fs: %s", t, Server.StateNames[Server.GetState(model)]))
	check(Server.GetState(model) == S.Ragdoll, "heavy x2 fell")
	check(fell == 1, "Fell fired once")
	check(allKinematic(model) == false, "joints simulated")
	for _, j in joints do if j.Name == "Root" then check(j.IsKinematic == true, "Root stays rigid while limp") else check(j.IsKinematic == false and math.abs(j.AngularStrength - 0.04) < 1e-6, j.Name .. " limp") end end
	check(parts.HumanoidRootPart.CanCollide == false, "root no collide")
	local hs = store(hum)
	check(hs.changes[#hs.changes] == roblox.Enum.HumanoidStateType.Physics, "driver put Humanoid in Physics")
	check(hum:GetStateEnabled(roblox.Enum.HumanoidStateType.GettingUp) == false, "GettingUp disabled")
	run(0.2)
	check(parts.LeftHand.CanCollide == true, "limbs collide while ragdolled")

	-- Heavy preset: RagdollDuration 4.5
	local t2 = run(10, function() return Server.GetState(model) == S.Recovering end)
	check(math.abs(t2 + 0.2 - 4.5) < 0.1, string.format("stood up after RagdollDuration (%.2fs + 0.2s)", t2))
	-- Getting up: legs firm, upper body soft so it swings, root pulled up by springs.
	check(joints.LeftHip.IsKinematic and not joints.Waist.IsKinematic, "legs firm, upper body soft while getting up")
	run(0.4)
	check(hs.changes[#hs.changes] == roblox.Enum.HumanoidStateType.Physics, "Physics while getting up")
	check(parts.HumanoidRootPart:FindFirstChildOfClass("AlignPosition") ~= nil, "springs pull the body up, no CFrame snap")
	run(1.0)
	check(hs.changes[#hs.changes] == roblox.Enum.HumanoidStateType.GettingUp, "GettingUp once on their feet")
	check(parts.HumanoidRootPart:FindFirstChildOfClass("AlignPosition") == nil, "springs released")
	check(hum.WalkSpeed == 16 and Server.GetState(model) == S.Recovering, "ready to move before the server calls it over")
	local t3 = run(5, function() return Server.GetState(model) == S.Idle end)
	check(math.abs(t3 + 1.4 - 1.5) < 0.1, string.format("idle right after the get-up (%.2fs + 1.4s)", t3))
	check(recoveredSignal == 1, "Recovered fired once")
	check(hum.WalkSpeed == 16 and hum:GetStateEnabled(roblox.Enum.HumanoidStateType.GettingUp) == true, "humanoid restored")
	c1:Disconnect(); c2:Disconnect()
	model:Destroy(); localPlayer.Character = nil
end)

scenario("NPC: server drives itself", function()
	local model, hum = buildCharacter("Npc")
	check(Server.Begin(model, roblox.Vector3.xAxis, { Seed = 11 }), "Begin npc")
	local sc = Server.GetController(model)
	check(sc.IsDriver == true, "server drives NPC")
	check(store(model.UpperTorso).owner == "server" and store(model.LeftFoot).owner == "server", "server owns the NPC's physics")
	local cc = Client.GetController(model)
	check(cc and cc.IsDriver == false, "client only observes NPC")
	check(cc.Balance ~= nil, "client runs its own copy of the NPC's balance to draw the pose")
	run(0.3)
	check(#store(hum).moves > 0, "server moved NPC")
	-- Nothing animates this rig, so the pose must not compound frame after frame.
	local _, spin = peerTransform(jointsOf(model).Waist, "server"):ToAxisAngle()
	check(spin < 1, string.format("NPC pose layered once, not compounded (waist %.2f rad)", spin))
	local t = run(10, function() return Server.GetState(model) ~= S.Staggering end)
	print(string.format("  decided after %.2fs: %s", t, Server.StateNames[Server.GetState(model)]))
	local reports = 0
	for _, e in BRIDGE.log do if e.name == "Stagger.Report" and e.args[1] == model then reports += 1 end end
	check(reports == 0, "no client report for NPC")
	run(10, function() return Server.GetState(model) == S.Idle end)
	for _, j in jointsOf(model) do local tf = peerTransform(j, "server") check(tf.Position.Magnitude < 1e-3 and tf.XVector.X > 0.9999 and tf.YVector.Y > 0.9999, "NPC " .. j.Name .. " pose cleared") end
	check(Server.GetState(model) == S.Idle and allKinematic(model), "npc idle and restored (state=" .. Server.StateNames[Server.GetState(model)] .. " kinematic=" .. tostring(allKinematic(model)) .. ")")
	model:Destroy()
end)

scenario("Direct Ragdoll with RagdollDuration 0 waits for Recover; Stop cancels", function()
	Server.RegisterPreset("Down", Server.Presets.Default, { RagdollDuration = 0 })
	Client.RegisterPreset("Down", Client.Presets.Default, { RagdollDuration = 0 })
	local model, hum = playerCharacter("Kash")
	check(Server.Ragdoll(model, { Preset = "Down" }) == true, "Ragdoll ok")
	check(Server.GetState(model) == S.Ragdoll and Client.GetState(model) == S.Ragdoll, "both ragdolled")
	run(6)
	check(Server.GetState(model) == S.Ragdoll, "stays down")
	check(Server.Begin(model, roblox.Vector3.xAxis) == false, "Begin refused while ragdolled")
	Server.Recover(model)
	check(Server.GetState(model) == S.Recovering, "recovering")
	run(1.7) -- get-up animation
	check(Server.GetState(model) == S.Idle, "idle")

	check(Server.Begin(model, roblox.Vector3.xAxis, { Preset = "Drunk", Seed = 5 }), "begin drunk")
	run(0.5)
	Server.Stop(model)
	check(Server.GetState(model) == S.Idle and Client.GetState(model) == S.Idle, "Stop -> idle everywhere")
	check(allKinematic(model) and hum.WalkSpeed == 16 and not model:HasTag("Staggering"), "Stop restored")
	model:Destroy(); localPlayer.Character = nil
end)

scenario("Re-hit while staggering restarts the lurch", function()
	local model = playerCharacter("Kash")
	Server.Begin(model, roblox.Vector3.xAxis, { Preset = "Drunk", Seed = 1 })
	run(0.5)
	local before = Client.GetController(model).Balance.Time
	check(Server.Begin(model, -roblox.Vector3.zAxis, { Preset = "Drunk", Seed = 2 }), "second Begin ok")
	local b = Client.GetController(model).Balance
	check(b.Time < before, "balance model restarted")
	check(b.Direction.Z < -0.5, "new direction dominates")
	local fresh = Client.Presets.Drunk.StartBalance
	check(b.Balance <= fresh - Client.Presets.Drunk.ReHitBalanceLoss + 1e-6, string.format("re-hit keeps you lower (%.2f vs fresh %.2f)", b.Balance, fresh))
	Server.Stop(model)
	model:Destroy(); localPlayer.Character = nil
end)

scenario("Low balance holds the lurch speed; MomentumHold 0 keeps the old slowdown", function()
	Server.RegisterPreset("NoHold", Server.Presets.Default, { MomentumHold = 0 })
	Client.RegisterPreset("NoHold", Client.Presets.Default, { MomentumHold = 0 })
	local model = playerCharacter("Kash")
	local function speedAfter(preset)
		Server.Begin(model, roblox.Vector3.xAxis, { Preset = preset, Seed = 3 })
		local b = Client.GetController(model).Balance
		b.Balance, b.Stepping, b.NextStepAt = 0.05, false, math.huge -- far gone, no step to save them
		local start = b.Speed > 0 and b.Speed or b.Momentum.Magnitude
		b:Step(0.5)
		return start, b.Speed
	end
	local start, held = speedAfter("Default")
	check(held > start * 0.95, string.format("speed held at low balance (%.1f -> %.1f)", start, held))
	local start2, slowed = speedAfter("NoHold")
	check(slowed < start2 - 0.3, string.format("MomentumHold 0 still slows (%.1f -> %.1f)", start2, slowed))
	Server.Stop(model)
	model:Destroy(); localPlayer.Character = nil
end)

scenario("The body turns to face the way it is thrown", function()
	local model = playerCharacter("Kash")
	local root = model.HumanoidRootPart
	-- No physics engine here, so check the spin constraint the driver sets up instead.
	local function spinAfter(dir)
		root.CFrame = roblox.CFrame.new(root.CFrame.Position) -- facing -Z
		Server.Begin(model, dir, { Seed = 5 })
		run(0.1)
		local spin = root:FindFirstChildOfClass("AngularVelocity")
		local rate = if spin and spin.Enabled then spin.AngularVelocity.Y else 0
		Server.Stop(model)
		run(0.1)
		return rate
	end
	check(math.abs(spinAfter(roblox.Vector3.xAxis)) > 1, "thrown sideways: turns")
	check(math.abs(spinAfter(roblox.Vector3.zAxis)) > 1, "thrown backwards (hit from the front): turns round")
	check(spinAfter(-roblox.Vector3.zAxis) == 0, "thrown forwards (hit from behind): already facing it")
	check(root:FindFirstChildOfClass("AngularVelocity") == nil, "spin constraint cleaned up")
	model:Destroy(); localPlayer.Character = nil
end)

scenario("Recover in mid-air keeps falling instead of floating", function()
	Server.RegisterPreset("Down", Server.Presets.Default, { RagdollDuration = 0 })
	Client.RegisterPreset("Down", Client.Presets.Default, { RagdollDuration = 0 })
	local model, hum, parts = playerCharacter("Kash")
	Server.Ragdoll(model, { Preset = "Down" })
	run(0.2)
	AIRBORNE = true
	Server.Recover(model)
	run(0.1)
	AIRBORNE = false
	local hs = store(hum)
	check(hs.changes[#hs.changes] == roblox.Enum.HumanoidStateType.Freefall, "Freefall, not a get-up")
	check(parts.HumanoidRootPart:FindFirstChildOfClass("AlignPosition") == nil, "no springs holding them up")
	check(hum.WalkSpeed == 16, "control back straight away")
	run(2)
	Server.Stop(model)
	model:Destroy(); localPlayer.Character = nil
end)

scenario("Death during stagger releases without restoring joints", function()
	local model, hum = playerCharacter("Kash")
	Server.Begin(model, roblox.Vector3.xAxis, { Seed = 9 })
	run(0.3)
	hum.Health = 0
	store(hum).Died:Fire()
	check(Server.GetState(model) == S.Idle and Client.GetState(model) == S.Idle, "idle after death on both peers")
	check(not model:HasTag("Staggering") and model:GetAttribute("StaggerState") == nil, "tag/attribute cleared")
	check(allKinematic(model) == false, "joints left as they were (corpse)")
	check(Server.Begin(model, roblox.Vector3.xAxis) == false, "dead character refused")
	model:Destroy(); localPlayer.Character = nil
end)

scenario("Character removed mid-stagger unbinds", function()
	local model = buildCharacter("Npc2")
	Server.Begin(model, roblox.Vector3.xAxis, { Seed = 4 })
	check(#Server.GetCharacters() == 1, "bound")
	model.Parent = nil
	store(model).AncestryChanged:Fire(model, nil)
	check(#Server.GetCharacters() == 0 and #Client.GetCharacters() == 0, "unbound on both peers")
	run(1) -- timers must not blow up
end)

scenario("Late joiner receives current state", function()
	local model = buildCharacter("Npc3")
	Server.Begin(model, roblox.Vector3.xAxis, { Preset = "Drunk", Seed = 4 })
	local n = #BRIDGE.log
	peers.server.Players.PlayerAdded:Fire(localPlayer)
	check(#BRIDGE.log == n + 1 and BRIDGE.log[n + 1].player == localPlayer and BRIDGE.log[n + 1].args[2] == S.Staggering, "FireClient with current state")
	Server.Stop(model); model:Destroy()
end)

scenario("Client cannot spoof another character's outcome", function()
	local npc = buildCharacter("Npc4")
	Server.Begin(npc, roblox.Vector3.xAxis, { Seed = 4 })
	BRIDGE.setCurrent("client")
	BRIDGE.client["Stagger.Report"]:Fire(npc, S.Ragdoll)
	BRIDGE.setCurrent("server")
	check(Server.GetState(npc) == S.Staggering, "report for someone else's character ignored")
	Server.Stop(npc); npc:Destroy()
end)

scenario("Outcome distribution (client-driven, 40 seeds)", function()
	local fell, rec = 0, 0
	for seed = 1, 40 do
		local model = playerCharacter("Kash")
		Server.Begin(model, roblox.Vector3.xAxis, { Preset = "Default", Intensity = 1.5, Seed = seed })
		run(10, function() return Server.GetState(model) ~= S.Staggering end)
		if Server.GetState(model) == S.Ragdoll then fell += 1 else rec += 1 end
		Server.Stop(model)
		model:Destroy(); localPlayer.Character = nil
	end
	print(string.format("  Default x1.5: fell %d recovered %d", fell, rec))
	check(fell > 0 and rec > 0, "both outcomes occur")
end)

print(string.format("\n%d checks passed, %d failed", passed, failed))
if #peers.server.warnings > 1 or #peers.client.warnings > 0 then
	print("warnings:", table.concat(peers.server.warnings, " | "), table.concat(peers.client.warnings, " | "))
end
if failed > 0 then error("tests failed") end

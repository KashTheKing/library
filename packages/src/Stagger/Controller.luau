--!strict
--[=[
	@class Controller
	One per character that is staggering, ragdolled or getting up, on every peer. [Stagger]
	creates them through a [Binder](/api/Binder) and hands each a Trove that is cleaned when
	the stagger ends or the character leaves.

	Only the **driver** does real work: the network owner of the character, which is the
	player's own client for player characters and the server for NPCs. The driver runs the
	[Balance] model every `Heartbeat`, turns it into `Humanoid:Move` pulses (the little
	catch-up steps), writes the procedural pose into each joint's `Transform` during
	`PreSimulation` (leaning, arms out, leg swings, head counter-rotation), and reports the
	outcome. Other peers hold the controller only so [Stagger.GetState] and the signals work;
	they see the result through ordinary physics replication.

	You do not construct these yourself; read them with [Stagger.GetController].
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Balance = require(script.Parent.Balance)
local Config = require(script.Parent.Config)
local Rig = require(script.Parent.Rig)

type Trove = any

export type State = number

export type Payload = {
	Direction: Vector3,
	Seed: number,
	Intensity: number,
	Preset: string,
	Config: Config.Config,
}

export type Controller = {
	Character: Model,
	Trove: Trove,
	Rig: Rig.Rig,
	Humanoid: Humanoid,
	IsDriver: boolean,
	State: State,
	Config: Config.Config,
	Preset: string,
	Balance: Balance.Balance?,
	Direction: Vector3,
	Seed: number,
	Intensity: number,
	Decided: boolean,
	AirTime: number,
	Saved: { WalkSpeed: number, Jumping: boolean, GettingUp: boolean, FallingDown: boolean }?,
	OnOutcome: ((controller: Controller, outcome: Balance.Outcome) -> ())?,

	SetState: (self: Controller, state: State, payload: Payload?) -> (),
	Destroy: (self: Controller) -> (),
}

local STATE = table.freeze({ Idle = 0, Staggering = 1, Ragdoll = 2, Recovering = 3 })

local Controller = {}
Controller.__index = Controller
Controller.STATE = STATE

local isServer = RunService:IsServer()

local function isDriverFor(character: Model): boolean
	local player = Players:GetPlayerFromCharacter(character)
	if isServer then
		return player == nil
	end
	return player ~= nil and player == Players.LocalPlayer
end

--[=[
	@function new
	@within Controller
	@private
	Called by the Binder. `rig` is what the Binder's predicate returned.
]=]
function Controller.new(character: Model, trove: Trove, rig: Rig.Rig): Controller
	local self: Controller = setmetatable({
		Character = character,
		Trove = trove,
		Rig = rig,
		Humanoid = rig.Humanoid,
		IsDriver = isDriverFor(character),
		State = STATE.Idle,
		Config = Config.Default,
		Preset = "Default",
		Balance = nil,
		Direction = -Vector3.zAxis,
		Seed = 0,
		Intensity = 1,
		Decided = false,
		AirTime = 0,
		Saved = nil,
		OnOutcome = nil,
	} :: any, Controller) :: any

	-- Per-state connections live in this sub-trove so a state change can drop them.
	;(self :: any)._stateTrove = trove:Extend()
	return self
end

-- PlayerModule controls, when we are the local player's character and the module is there.
local controlsCache: any = nil
local function getControls(): any
	if isServer then
		return nil
	end
	if controlsCache ~= nil then
		return controlsCache or nil
	end
	local ok, controls = pcall(function()
		local player = Players.LocalPlayer
		local scripts = player:FindFirstChildOfClass("PlayerScripts")
		local module = scripts and scripts:FindFirstChild("PlayerModule")
		if not module then
			return nil
		end
		return (require :: any)(module):GetControls()
	end)
	controlsCache = if ok and controls then controls else false
	return controlsCache or nil
end

local function horizontalLook(cf: CFrame): Vector3
	local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(cf.UpVector.X, 0, cf.UpVector.Z)
	end
	if look.Magnitude < 1e-3 then
		look = -Vector3.zAxis
	end
	return look.Unit
end

-- Rotation that tips +Y towards `localDir` (a direction in the part's local space) by `angle`.
local function leanTowards(localDir: Vector3, angle: number): CFrame
	local flat = Vector3.new(localDir.X, 0, localDir.Z)
	if flat.Magnitude < 1e-3 or math.abs(angle) < 1e-4 then
		return CFrame.identity
	end
	local axis = Vector3.yAxis:Cross(flat.Unit)
	return CFrame.fromAxisAngle(axis.Unit, angle)
end

-- What we layered onto each joint last frame. The Animator rewrites Transform every frame while
-- an animation plays, but a rig with nothing playing (a bare NPC) keeps whatever we wrote, and
-- multiplying onto that again would compound the pose frame after frame. So when the joint
-- still holds our last write, layer onto the base we used then instead.
local layered: { [AnimationConstraint]: { Base: CFrame, Written: CFrame } } = setmetatable({}, { __mode = "k" }) :: any

-- Transform is stored at lower precision than a CFrame, so compare with a little slack.
local function sameTransform(a: CFrame, b: CFrame): boolean
	return (a.Position - b.Position).Magnitude < 1e-3 and a.XVector:Dot(b.XVector) > 0.99995 and a.YVector:Dot(b.YVector) > 0.99995
end

local function multiplyTransform(joint: AnimationConstraint?, offset: CFrame)
	if joint then
		local last = layered[joint]
		local base = if last and sameTransform(joint.Transform, last.Written) then last.Base else joint.Transform
		local written = offset * base
		joint.Transform = written
		layered[joint] = { Base = base, Written = written }
	end
end

-- Takes our layer back off, so a rig nothing animates is left in the pose it had before.
local function clearTransforms(rig: Rig.Rig)
	for _, joint in rig.Joints do
		local last = layered[joint]
		if last then
			if sameTransform(joint.Transform, last.Written) then
				joint.Transform = last.Base
			end
			layered[joint] = nil
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Driver: staggering
--------------------------------------------------------------------------------------------------

local function poseStaggering(self: Controller)
	local balance = self.Balance
	if not balance then
		return
	end
	local cfg = self.Config
	local joints = self.Rig.Joints
	local root = self.Rig.RootPart
	local t = balance.Time

	local dirLocal = root.CFrame:VectorToObjectSpace(balance.Direction)
	local lean = balance:Lean()
	local sway = balance.Sway
	local raise = balance:ArmRaise()

	-- Whole body: lean into the lurch, sway sideways.
	local bodyLean = leanTowards(dirLocal, lean * 0.55) * CFrame.Angles(0, 0, sway * 0.25)
	multiplyTransform(joints.Root, bodyLean)

	-- Upper torso adds more lean and twists as the arms windmill.
	local waist = leanTowards(dirLocal, lean * 0.45) * CFrame.Angles(0, math.sin(t * 5.1) * 0.12 * raise, sway * 0.2)
	multiplyTransform(joints.Waist, waist)

	-- Head fights to stay level and looks where the body is going.
	local head = leanTowards(dirLocal, -lean * cfg.HeadCounter) * CFrame.Angles(0, -sway * 0.3, 0)
	multiplyTransform(joints.Neck, head)

	-- Arms come out to the sides and flail. Right arm is +X, so right raises with +Z rotation.
	local armOut = cfg.ArmRaise * raise
	local flail = cfg.ArmFlail * raise
	local rFlail = math.sin(t * 9.7) * flail
	local lFlail = math.sin(t * 9.7 + 2.3) * flail
	multiplyTransform(joints.RightShoulder, CFrame.Angles(0.3 * raise + rFlail, 0, armOut))
	multiplyTransform(joints.LeftShoulder, CFrame.Angles(0.3 * raise + lFlail, 0, -armOut))
	multiplyTransform(joints.RightElbow, CFrame.Angles(0.4 * raise, 0, 0))
	multiplyTransform(joints.LeftElbow, CFrame.Angles(0.4 * raise, 0, 0))

	-- Legs: the stepping leg swings forward at the hip and bends at the knee; the other
	-- one is the planted stance leg with a little bend so the pose reads as crouched.
	local phase = if balance.Stepping then math.sin(balance.StepPhase * math.pi) else 0
	local swing = cfg.StepSwing * phase * (if balance.StepIsStutter then 0.55 else 1)
	local bend = cfg.KneeBend * phase
	local stepping, planted
	if balance.StepLeg == "Left" then
		stepping, planted = "Left", "Right"
	else
		stepping, planted = "Right", "Left"
	end
	multiplyTransform(joints[stepping .. "Hip"], CFrame.Angles(swing, 0, 0))
	multiplyTransform(joints[stepping .. "Knee"], CFrame.Angles(-bend, 0, 0))
	multiplyTransform(joints[planted .. "Hip"], CFrame.Angles(0.12 * raise, 0, 0))
	multiplyTransform(joints[planted .. "Knee"], CFrame.Angles(-0.25 * raise, 0, 0))
end

local function updateStaggering(self: Controller, dt: number)
	local balance = self.Balance
	if not balance or self.Decided then
		return
	end
	local cfg = self.Config
	local humanoid = self.Humanoid

	local outcome = balance:Step(dt)

	-- Off a ledge: no floor for a while means the feet cannot save this.
	if humanoid.FloorMaterial == Enum.Material.Air then
		self.AirTime += dt
		if self.AirTime >= cfg.AirFallTime then
			outcome = "Fell"
		end
	else
		self.AirTime = 0
	end

	-- Little steps forward: move only while a foot is in the air, then stop and wobble.
	humanoid.WalkSpeed = math.clamp(balance.Speed, 0, cfg.MaxWalkSpeed)
	if balance.Stepping and balance.Speed > 0.1 then
		humanoid:Move(balance.Direction, false)
	else
		humanoid:Move(Vector3.zero, false)
	end

	if outcome ~= "Staggering" then
		self.Decided = true
		humanoid:Move(Vector3.zero, false)
		local onOutcome = self.OnOutcome
		if onOutcome then
			onOutcome(self, outcome)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Driver: ragdoll & getting up
--------------------------------------------------------------------------------------------------

local function updateRagdoll(self: Controller)
	-- The Humanoid clears CanCollide on limbs every step; put it back so the body lies on things.
	for _, limb in self.Rig.Limbs do
		if not limb.CanCollide then
			limb.CanCollide = true
		end
	end
	local root = self.Rig.RootPart
	if root.CanCollide then
		root.CanCollide = false
	end
end

local function standUp(self: Controller)
	local rig = self.Rig
	local root = rig.RootPart
	local torso = rig.LowerTorso
	local look = horizontalLook(rig.UpperTorso.CFrame)
	-- Put the root where the hips are, upright, facing the way the torso was pointing; with
	-- the joints kinematic again the whole body snaps to it and GettingUp lifts it to HipHeight.
	root.CFrame = CFrame.lookAlong(torso.Position, look)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	for _, limb in rig.Limbs do
		limb.AssemblyLinearVelocity = Vector3.zero
		limb.AssemblyAngularVelocity = Vector3.zero
	end
	self.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
end

--------------------------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------------------------

-- WalkSpeed and SetStateEnabled only matter on the peer that runs the Humanoid, so the driver
-- saves them once and puts them back when the stagger is over.
local function saveHumanoid(self: Controller)
	if self.Saved then
		return
	end
	local humanoid = self.Humanoid
	self.Saved = {
		WalkSpeed = humanoid.WalkSpeed,
		Jumping = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping),
		GettingUp = humanoid:GetStateEnabled(Enum.HumanoidStateType.GettingUp),
		FallingDown = humanoid:GetStateEnabled(Enum.HumanoidStateType.FallingDown),
	}
end

local function restoreHumanoid(self: Controller)
	local saved = self.Saved
	if not saved then
		return
	end
	self.Saved = nil
	local humanoid = self.Humanoid
	if not humanoid.Parent then
		return
	end
	humanoid.WalkSpeed = saved.WalkSpeed
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, saved.Jumping)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, saved.GettingUp)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, saved.FallingDown)
end

local function setControlsEnabled(self: Controller, enabled: boolean)
	if isServer or not self.Config.DisableControls then
		return
	end
	local controls = getControls()
	if controls then
		if enabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end
end

--[=[
	Moves the controller into `state`, tearing down what the previous state set up on this peer.
	Called by [Stagger] on every peer as the server's state packets arrive.

	@method SetState
	@within Controller
	@private
	@param state State
	@param payload Payload? -- Required when entering Staggering: direction, seed, intensity, preset and config.
]=]
function Controller.SetState(self: Controller, state: State, payload: Payload?)
	local stateTrove = (self :: any)._stateTrove
	stateTrove:Clean()
	clearTransforms(self.Rig)

	local previous = self.State
	self.State = state
	self.Decided = false
	self.AirTime = 0

	if payload then
		self.Direction = payload.Direction
		self.Seed = payload.Seed
		self.Intensity = payload.Intensity
		self.Preset = payload.Preset
		self.Config = payload.Config
	end

	if not self.IsDriver then
		self.Balance = nil
		return
	end

	local humanoid = self.Humanoid
	if state == STATE.Staggering then
		self.Balance = Balance.new(self.Config, self.Direction, self.Intensity, self.Seed)
		saveHumanoid(self)
		setControlsEnabled(self, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		humanoid:Move(Vector3.zero, false)
		stateTrove:Connect(RunService.Heartbeat, function(dt)
			updateStaggering(self, dt)
		end)
		stateTrove:Connect(RunService.PreSimulation, function()
			poseStaggering(self)
		end)
	elseif state == STATE.Ragdoll then
		self.Balance = nil
		saveHumanoid(self)
		setControlsEnabled(self, false)
		humanoid.WalkSpeed = (self.Saved :: any).WalkSpeed
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		humanoid:Move(Vector3.zero, false)
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		stateTrove:Connect(RunService.Heartbeat, function()
			updateRagdoll(self)
		end)
	elseif state == STATE.Recovering then
		self.Balance = nil
		saveHumanoid(self)
		humanoid.WalkSpeed = (self.Saved :: any).WalkSpeed
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, (self.Saved :: any).FallingDown)
		humanoid:Move(Vector3.zero, false)
		if previous == STATE.Ragdoll then
			standUp(self)
		end
	else
		self.Balance = nil
		humanoid:Move(Vector3.zero, false)
		restoreHumanoid(self)
		setControlsEnabled(self, true)
	end
end

--[=[
	@method Destroy
	@within Controller
	@private
	Cleaned by the Binder's Trove; re-enables controls if this peer disabled them.
]=]
function Controller.Destroy(self: Controller)
	(self :: any)._stateTrove:Clean()
	clearTransforms(self.Rig)
	if self.IsDriver then
		restoreHumanoid(self)
		setControlsEnabled(self, true)
		if self.Humanoid.Parent then
			self.Humanoid:Move(Vector3.zero, false)
		end
	end
end

return Controller

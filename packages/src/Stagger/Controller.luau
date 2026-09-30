--!strict
--[=[
	@class Controller
	One per character that is staggering, ragdolled or getting up, on every peer. [Stagger]
	creates them through a [Binder](/api/Binder) and hands each a Trove that is cleaned when
	the stagger ends or the character leaves.

	Only the **driver** does real work: the network owner of the character, which is the
	player's own client for player characters and, for NPCs, the client of the nearest player
	(the server when nobody is near). The driver runs the
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
	Driver: Player?,
	State: State,
	Config: Config.Config,
	Preset: string,
	Balance: Balance.Balance?,
	Direction: Vector3,
	Seed: number,
	Intensity: number,
	Decided: boolean,
	AirTime: number,
	GetUp: any,
	PausedAnimate: Instance?,
	Spin: AngularVelocity?,
	FaceDirection: Vector3?,
	Drive: LinearVelocity?,
	Saved: { WalkSpeed: number, Jumping: boolean, GettingUp: boolean, FallingDown: boolean }?,
	OnOutcome: ((controller: Controller, outcome: Balance.Outcome) -> ())?,

	SetDriver: (self: Controller, driver: Player?) -> (),
	SetState: (self: Controller, state: State, payload: Payload?) -> (),
	Destroy: (self: Controller) -> (),
}

local STATE = table.freeze({ Idle = 0, Staggering = 1, Ragdoll = 2, Recovering = 3 })

local Controller = {}
Controller.__index = Controller
Controller.STATE = STATE

local isServer = RunService:IsServer()

-- The peer that simulates the character: its own player for a player character, otherwise the
-- driver the server picked (a nearby player), or the server when there is none.
local function isDriverFor(character: Model, driver: Player?): boolean
	local player = Players:GetPlayerFromCharacter(character) or driver
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
		IsDriver = isDriverFor(character, nil),
		Driver = nil,
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
		-- Older places copy PlayerModule into PlayerScripts; newer ones run it from StarterPlayer.
		local module = (scripts and scripts:FindFirstChild("PlayerModule"))
			or game:GetService("StarterPlayer"):FindFirstChild("PlayerModule")
		if not module then
			return nil
		end
		local playerModule = (require :: any)(module)
		if type(playerModule) == "table" and playerModule.GetControls then
			return playerModule:GetControls()
		end
		-- The StarterPlayer layout has no GetControls; its ControlModule has the same Enable/Disable.
		local controlModule = module:FindFirstChild("ControlModule")
		return controlModule and (require :: any)(controlModule)
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
		if last then
			last.Base, last.Written = base, written
		else
			layered[joint] = { Base = base, Written = written }
		end
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

-- How far the body is turned away from the lurch: the angle to turn (positive is to the left) so
-- the character faces the way they are being thrown and stumbles forward into it.
local function headingError(dirLocal: Vector3): number
	if dirLocal.X * dirLocal.X + dirLocal.Z * dirLocal.Z < 1e-6 then
		return 0
	end
	return math.atan2(-dirLocal.X, -dirLocal.Z)
end

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
	-- The flinch: a sharp extra snap with the hit that fades over a fifth of a second, so the
	-- body reacts on the first frame instead of easing into the lean.
	local flinch = math.max(0, 1 - t / 0.2) ^ 2 * 0.45 * math.min(self.Intensity, 2)
	local lean = balance:Lean() + flinch
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

	-- Legs: the stepping leg swings towards the lurch at the hip and bends at the knee; the other
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
	-- The foot reaches the way the body is going: forward, back, or across.
	multiplyTransform(joints[stepping .. "Hip"], leanTowards(dirLocal, -swing))
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

	-- Steering: the player's walk input bends the lurch towards it, a little at a time, so they
	-- can guide the stumble but not cancel it.
	local input = if isServer then nil else humanoid.MoveDirection
	if input and cfg.Steering > 0 and balance.Speed > 0.5 then
		local from = Vector3.new(balance.Momentum.X, 0, balance.Momentum.Z)
		local to = Vector3.new(input.X, 0, input.Z)
		if from.Magnitude > 1e-3 and to.Magnitude > 0.1 then
			local angle = math.atan2(from.Unit:Cross(to.Unit).Y, from.Unit:Dot(to.Unit))
			local turn = math.clamp(angle, -cfg.Steering * dt, cfg.Steering * dt) * math.min(to.Magnitude, 1)
			balance.Momentum = CFrame.fromAxisAngle(Vector3.yAxis, turn):VectorToWorldSpace(balance.Momentum)
		end
	end
	-- Walking with the stumble (input lined up with the lurch) is catching yourself.
	local catch = 0
	if input and cfg.Steering > 0 then
		local flat = Vector3.new(input.X, 0, input.Z)
		if flat.Magnitude > 0.1 then
			catch = math.max(flat.Unit:Dot(balance.Direction), 0) * math.min(flat.Magnitude, 1)
		end
	end
	local outcome = balance:Step(dt, catch)

	-- Face the lurch: a spin constraint keeps turning the body towards where it is being thrown,
	-- following the direction as missteps and re-hits change it.
	local spin = self.Spin
	if spin then
		local root = self.Rig.RootPart
		-- Face a smoothed lurch direction: missteps kick the body sideways and chasing every kick
		-- would whip it round. Nearly stopped, the direction is just noise, so hold the heading.
		local face = self.FaceDirection or balance.Direction
		if balance.Speed > 2 then
			face = (face + (balance.Direction - face) * math.min(dt * 3, 1))
			face = if face.Magnitude > 1e-3 then face.Unit else balance.Direction
		end
		self.FaceDirection = face
		local err = if balance.Speed > 2 then headingError(root.CFrame:VectorToObjectSpace(face)) else 0
		local rate = 0
		if math.abs(err) > 0.02 then
			rate = math.clamp(err / math.max(dt, 1e-3), -cfg.TurnSpeed, cfg.TurnSpeed)
			if not spin.Enabled then
				spin.Enabled = true
			end
		end
		-- Constraint properties are written only on a real change: on a server-driven NPC every
		-- write replicates to every client.
		if math.abs(spin.AngularVelocity.Y - rate) > 1e-3 then
			spin.AngularVelocity = Vector3.new(0, rate, 0)
		end
	end

	-- Off a ledge: no floor for a while means the feet cannot save this.
	if humanoid.FloorMaterial == Enum.Material.Air then
		self.AirTime += dt
		if self.AirTime >= cfg.AirFallTime then
			outcome = "Fell"
		end
	else
		self.AirTime = 0
	end

	-- Little steps: surge while a foot is in the air, then nearly stop and wobble. The drive is a
	-- LinearVelocity on the root, so no control script can overwrite it.
	local drive = self.Drive
	if drive then
		local speed = math.min(balance.Speed, cfg.MaxWalkSpeed) * (if balance.Stepping then 1 else 0.25)
		local velocity = balance.Direction * speed
		local plane = Vector2.new(velocity.X, velocity.Z)
		if (plane - drive.PlaneVelocity).Magnitude > 0.05 then
			drive.PlaneVelocity = plane
		end
	end

	if outcome ~= "Staggering" then
		self.Decided = true
		if drive then
			drive.PlaneVelocity = Vector2.zero
		end
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

-- Getting up from the floor is a short procedural animation, not a snap. The plan is worked out
-- from how the body is lying when it starts: face down pushes up on the arms and pulls the knees
-- under; face up sits up and tucks the feet. `u` runs 0 -> 1 over `GetUpTime`.
type GetUpPlan = { Elapsed: number, FaceDown: boolean, Hips: Vector3, Yaw: CFrame, Stand: number, Floor: number, Lift: number, Airborne: boolean }

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Piecewise-linear through keyframes { {u, value}, ... }, eased in and out between them.
local function keyed(frames: { { number } }, u: number): number
	for i = 2, #frames do
		local a, b = frames[i - 1], frames[i]
		if u <= b[1] then
			local t = (u - a[1]) / math.max(b[1] - a[1], 1e-4)
			t = t * t * (3 - 2 * t)
			return lerp(a[2], b[2], t)
		end
	end
	return frames[#frames][2]
end

local rad = math.rad
-- Keyframes in degrees (and studs above the floor for Height). Pitch tips the whole body forward.
local GET_UP = {
	FaceDown = {
		Pitch = { { 0, 90 }, { 0.35, 55 }, { 0.65, 25 }, { 1, 0 } },
		Height = { { 0, 0.9 }, { 0.35, 1.35 }, { 0.65, 1.9 }, { 1, 1 } },
		Hip = { { 0, 0 }, { 0.35, 100 }, { 0.65, 75 }, { 1, 0 } },
		Knee = { { 0, 0 }, { 0.35, -115 }, { 0.65, -95 }, { 1, 0 } },
		Shoulder = { { 0, 60 }, { 0.2, 95 }, { 0.5, 60 }, { 0.8, 15 }, { 1, 0 } },
		Elbow = { { 0, 60 }, { 0.3, 10 }, { 1, 0 } },
		Waist = { { 0, 0 }, { 0.35, 15 }, { 0.65, 10 }, { 1, 0 } },
	},
	FaceUp = {
		Pitch = { { 0, -90 }, { 0.4, -15 }, { 0.7, 30 }, { 1, 0 } },
		Height = { { 0, 0.8 }, { 0.4, 1.1 }, { 0.7, 2 }, { 1, 1 } },
		Hip = { { 0, 0 }, { 0.4, 85 }, { 0.7, 110 }, { 1, 0 } },
		Knee = { { 0, 0 }, { 0.4, -30 }, { 0.7, -125 }, { 1, 0 } },
		Shoulder = { { 0, 10 }, { 0.4, -30 }, { 0.7, 55 }, { 1, 0 } },
		Elbow = { { 0, 0 }, { 0.4, 30 }, { 0.7, 20 }, { 1, 0 } },
		Waist = { { 0, 0 }, { 0.4, 25 }, { 0.7, 20 }, { 1, 0 } },
	},
}

local function planGetUp(self: Controller): GetUpPlan
	local rig = self.Rig
	local torso = rig.UpperTorso.CFrame
	local faceDown = torso.LookVector.Y < 0
	-- Face down you get up facing where your head was; face up you sit up towards your feet.
	local headward = Vector3.new(torso.UpVector.X, 0, torso.UpVector.Z)
	if headward.Magnitude < 1e-3 then
		headward = horizontalLook(torso)
	end
	local forward = (if faceDown then headward else -headward).Unit
	-- The floor under the hips; a lying torso's own size says little about where that is.
	local hips = rig.LowerTorso.CFrame.Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	local hit = workspace:Raycast(hips + Vector3.new(0, 2, 0), Vector3.new(0, -8, 0), params)
	local floor = if hit then hit.Position.Y else hips.Y - 1
	return {
		-- Let go in mid-air: there is nothing to get up off, so they just keep falling.
		Airborne = hit == nil or hips.Y - floor > 2.5,
		Elapsed = 0,
		Floor = floor,
		Lift = 0,
		FaceDown = faceDown,
		Hips = Vector3.new(rig.LowerTorso.CFrame.Position.X, floor, rig.LowerTorso.CFrame.Position.Z),
		Yaw = CFrame.lookAlong(Vector3.zero, forward),
		Stand = self.Humanoid.HipHeight + rig.RootPart.Size.Y / 2,
	}
end

local function getUpProgress(self: Controller, plan: GetUpPlan): number
	return math.clamp(plan.Elapsed / math.max(self.Config.GetUpTime, 1e-3), 0, 1)
end

-- Every peer: bend the limbs through the get-up.
local function poseGettingUp(self: Controller, plan: GetUpPlan)
	local keys = if plan.FaceDown then GET_UP.FaceDown else GET_UP.FaceUp
	local u = getUpProgress(self, plan)
	local joints = self.Rig.Joints
	local hip, knee = rad(keyed(keys.Hip, u)), rad(keyed(keys.Knee, u))
	local shoulder, elbow = rad(keyed(keys.Shoulder, u)), rad(keyed(keys.Elbow, u))
	-- One leg leads so the rise reads as a lunge rather than a jump.
	local lead = math.sin(math.clamp((u - 0.45) / 0.4, 0, 1) * math.pi) * rad(35)
	multiplyTransform(joints.LeftHip, CFrame.Angles(hip + lead, 0, 0))
	multiplyTransform(joints.RightHip, CFrame.Angles(hip - lead, 0, 0))
	multiplyTransform(joints.LeftKnee, CFrame.Angles(knee, 0, 0))
	multiplyTransform(joints.RightKnee, CFrame.Angles(knee * (if u > 0.45 then 0.6 else 1), 0, 0))
	multiplyTransform(joints.LeftShoulder, CFrame.Angles(shoulder, 0, 0))
	multiplyTransform(joints.RightShoulder, CFrame.Angles(shoulder, 0, 0))
	multiplyTransform(joints.LeftElbow, CFrame.Angles(elbow, 0, 0))
	multiplyTransform(joints.RightElbow, CFrame.Angles(elbow, 0, 0))
	multiplyTransform(joints.Waist, CFrame.Angles(-rad(keyed(keys.Waist, u)), 0, 0))
end

-- Driver only: springs that carry the root from the floor to standing. The body is pulled toward
-- each keyframe rather than placed on it, so it has weight and lags a little; the upper body is
-- soft (Muscle mode on the server) and swings with it.
local function makeGetUpDrive(self: Controller, trove: any): (AlignPosition, AlignOrientation)
	local root = self.Rig.RootPart
	local attachment = trove:Add(Instance.new("Attachment"))
	attachment.Name = "StaggerGetUp"
	attachment.Parent = root
	local position = trove:Add(Instance.new("AlignPosition"))
	position.Mode = Enum.PositionAlignmentMode.OneAttachment
	position.Attachment0 = attachment
	position.Responsiveness = 30
	position.MaxForce = math.huge -- Responsiveness alone sets how hard it pulls
	position.Position = root.CFrame.Position
	position.Parent = root
	local orientation = trove:Add(Instance.new("AlignOrientation"))
	orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orientation.Attachment0 = attachment
	orientation.Responsiveness = 25
	orientation.MaxTorque = math.huge
	orientation.CFrame = root.CFrame
	orientation.Parent = root
	return position, orientation
end

-- Driver only: move the spring targets along the get-up. Returns true once standing.
local function moveGettingUp(self: Controller, plan: GetUpPlan, position: AlignPosition, orientation: AlignOrientation): boolean
	local keys = if plan.FaceDown then GET_UP.FaceDown else GET_UP.FaceUp
	local u = getUpProgress(self, plan)
	local pitch = rad(keyed(keys.Pitch, u))
	local height = if u >= 1 then plan.Stand else lerp(keyed(keys.Height, u), plan.Stand, math.clamp((u - 0.65) / 0.35, 0, 1))
	local rig = self.Rig
	-- Keep the body on the floor: whatever the keyframes say, the lowest point of the limbs is
	-- eased down onto the floor, so hands, knees and feet take the weight.
	if u < 1 then
		local lowest = math.huge
		for _, limb in rig.Limbs do
			local cf, half = limb.CFrame, limb.Size / 2
			local reach = math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z
			lowest = math.min(lowest, cf.Position.Y - reach)
		end
		if lowest < math.huge then
			plan.Lift += (plan.Floor - lowest) * 0.3
		end
		height += plan.Lift
	end
	position.Position = Vector3.new(plan.Hips.X, plan.Floor + height, plan.Hips.Z)
	orientation.CFrame = plan.Yaw * CFrame.Angles(-pitch, 0, 0)
	return u >= 1
end

--------------------------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------------------------

-- WalkSpeed and SetStateEnabled only matter on the peer that runs the Humanoid, so the driver
-- saves them once and puts them back when the stagger is over.
-- The default Animate script would keep playing walk and run cycles under the stagger pose and
-- the get-up, so it is paused (and its tracks stopped) for the whole stagger on the driver, whose
-- animations replicate to everyone else.
local function pauseAnimations(self: Controller)
	local animate = self.Character:FindFirstChild("Animate")
	if animate and (animate:IsA("LocalScript") or animate:IsA("Script")) and animate.Enabled then
		animate.Enabled = false
		self.PausedAnimate = animate
	end
	local animator = self.Humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0.15)
		end
	end
end

local function resumeAnimations(self: Controller)
	local animate = self.PausedAnimate
	self.PausedAnimate = nil
	if animate and animate.Parent then
		animate.Enabled = true
	end
end

local function saveHumanoid(self: Controller)
	if self.Saved then
		return
	end
	pauseAnimations(self)
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
	resumeAnimations(self)
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
	-- Only the local player's own character touches the controls; a client driving an NPC does not.
	if isServer or not self.Config.DisableControls or Players:GetPlayerFromCharacter(self.Character) ~= Players.LocalPlayer then
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
	Tells the controller who simulates the character: `nil` for the server (or the character's
	own player), a Player for an NPC driven by that player's client. [Stagger] calls it as the
	state packets arrive, before [Controller:SetState].

	@method SetDriver
	@within Controller
	@private
	@param driver Player?
]=]
function Controller.SetDriver(self: Controller, driver: Player?)
	local wasDriver = self.IsDriver
	self.Driver = driver
	self.IsDriver = isDriverFor(self.Character, driver)
	-- Demoted mid-stagger (the server took the NPC over): give this copy of the Humanoid back its
	-- settings now, since nothing else on this peer will.
	if wasDriver and not self.IsDriver and self.State ~= STATE.Idle then
		restoreHumanoid(self)
		setControlsEnabled(self, true)
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
	self.Spin = nil
	self.Drive = nil
	self.Decided = false
	self.AirTime = 0

	if payload then
		self.Direction = payload.Direction
		self.Seed = payload.Seed
		self.Intensity = payload.Intensity
		self.Preset = payload.Preset
		self.Config = payload.Config
	end

	-- Transform never replicates, so every client runs its own copy of the (seeded, so identical)
	-- balance model and draws the pose itself. Only the driver moves the character and decides.
	local previousBalance = self.Balance
	self.Balance = nil
	if state == STATE.Staggering and (self.IsDriver or not isServer) then
		local balance = Balance.new(self.Config, self.Direction, self.Intensity, self.Seed)
		if previousBalance and previous == STATE.Staggering then
			-- Hit again while still off balance: it only gets worse. Keep the lower balance, lose
			-- some more, and the old lurch adds to the new shove.
			balance.Balance = math.max(math.min(balance.Balance, previousBalance.Balance) - self.Config.ReHitBalanceLoss, 0)
			balance.Momentum += previousBalance.Momentum
			balance.Speed = balance.Momentum.Magnitude
			if balance.Speed > 1e-3 then
				balance.Direction = balance.Momentum.Unit
			end
		end
		self.Balance = balance
		stateTrove:Connect(RunService.PreSimulation, function()
			poseStaggering(self)
		end)
	end

	self.GetUp = nil
	if state == STATE.Recovering and previous == STATE.Ragdoll and (self.IsDriver or not isServer) then
		local plan = planGetUp(self)
		self.GetUp = plan
		if not plan.Airborne then
			stateTrove:Connect(RunService.PreSimulation, function(dt)
				plan.Elapsed += dt
				if getUpProgress(self, plan) < 1 then
					poseGettingUp(self, plan)
				end
			end)
		end
	end

	-- An NPC's Animate script runs on the server whoever drives it, so the server pauses it (the
	-- tracks replicate) for the whole stagger even while a client simulates the body.
	if isServer and not Players:GetPlayerFromCharacter(self.Character) then
		if state == STATE.Idle then
			resumeAnimations(self)
		else
			pauseAnimations(self)
		end
	end

	if not self.IsDriver then
		if self.Balance then
			local balance = self.Balance
			stateTrove:Connect(RunService.Heartbeat, function(dt)
				balance:Step(dt)
			end)
		end
		return
	end

	local humanoid = self.Humanoid
	if state == STATE.Staggering then
		local balance = self.Balance :: Balance.Balance
		local root = self.Rig.RootPart
		local spinAttachment = stateTrove:Add(Instance.new("Attachment"))
		spinAttachment.Name = "StaggerTurn"
		spinAttachment.Parent = root
		local spin = stateTrove:Add(Instance.new("AngularVelocity"))
		spin.Attachment0 = spinAttachment
		spin.RelativeTo = Enum.ActuatorRelativeTo.World
		spin.MaxTorque = math.huge
		spin.Enabled = false
		spin.Parent = root
		self.Spin = spin
		self.FaceDirection = balance.Direction
		saveHumanoid(self)
		-- With steering the controls stay on so their input can be read; the stagger still
		-- decides the actual move every frame (below).
		setControlsEnabled(self, self.Config.Steering > 0)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		-- The spin constraint does the turning; don't let the Humanoid swing round towards its
		-- move direction before the server's AutoRotate change arrives.
		humanoid.AutoRotate = false
		-- The lurch is driven by a horizontal LinearVelocity on the root: physics, not the
		-- Humanoid's walking, so input scripts can't overwrite it (walk input only steers, above).
		-- WalkSpeed 0 stops the Humanoid pulling against it.
		local drive = stateTrove:Add(Instance.new("LinearVelocity"))
		drive.Attachment0 = spinAttachment
		drive.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
		drive.PrimaryTangentAxis = Vector3.xAxis
		drive.SecondaryTangentAxis = Vector3.zAxis
		drive.RelativeTo = Enum.ActuatorRelativeTo.World
		drive.MaxForce = 1e6
		local shove = balance.Direction * math.min(balance.Speed, self.Config.MaxWalkSpeed)
		drive.PlaneVelocity = Vector2.new(shove.X, shove.Z) -- moving on the frame of the hit
		drive.Parent = root
		self.Drive = drive
		humanoid.WalkSpeed = 0
		local velocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(shove.X, velocity.Y, shove.Z)
		stateTrove:Connect(RunService.Heartbeat, function(dt)
			updateStaggering(self, dt)
		end)
	elseif state == STATE.Ragdoll then
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
		saveHumanoid(self)
		-- Still no control until the stagger is fully over.
		stateTrove:Connect(RunService.PreSimulation, function()
			humanoid:Move(Vector3.zero, false)
		end)
		humanoid.WalkSpeed = (self.Saved :: any).WalkSpeed
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, (self.Saved :: any).FallingDown)
		humanoid:Move(Vector3.zero, false)
		local plan = self.GetUp :: GetUpPlan?
		if plan and plan.Airborne then
			-- No floor to get up off: hand the body straight back and let it fall.
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
			restoreHumanoid(self)
			setControlsEnabled(self, true)
		elseif plan then
			humanoid:ChangeState(Enum.HumanoidStateType.Physics)
			local driveTrove = stateTrove:Extend()
			local position, orientation = makeGetUpDrive(self, driveTrove)
			local done = false
			stateTrove:Connect(RunService.Heartbeat, function()
				if not done and moveGettingUp(self, plan, position, orientation) then
					-- On their feet: hand the body back to the Humanoid and the player right away,
					-- rather than waiting for the server to call the stagger over.
					done = true
					driveTrove:Clean()
					humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
					restoreHumanoid(self)
					setControlsEnabled(self, true)
				end
			end)
		end
	else
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
	resumeAnimations(self)
end

return Controller

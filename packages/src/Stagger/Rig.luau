--!strict
--[=[
	@class Rig
	Finds the joints of an R15 character built with Roblox's Avatar Joint Upgrade (the
	`AnimationConstraint` and `BallSocketConstraint` pairs that replaced `Motor6D`) and
	switches them between three modes without ever adding or replacing a joint:

	- **Kinematic**: `IsKinematic = true`, the stock behaviour. Animations drive the parts exactly.
	- **Muscle**: the upper body (waist, neck, arms) is simulated with a soft `AngularStrength`
	  so it lags and swings with the body, while the root and legs stay kinematic so the
	  `Humanoid` keeps the character on its feet. This is the staggering look.
	- **Limp**: every joint is simulated with almost no strength, the ball sockets provide the
	  limits, and the character is a ragdoll.

	Everything a mode touches is snapshotted first so [Rig.restore] puts it all back.

	Only the server calls into this (joint properties replicate from the server, and the network
	owner simulates them). Rigs still on `Motor6D` are reported as unsupported: `Rig.get` returns
	`nil` and `Stagger` warns once, because the whole point is to use the joints Roblox already
	gave the character.
]=]

export type Mode = "Kinematic" | "Muscle" | "Limp"

type JointSnapshot = {
	IsKinematic: boolean,
	AngularStrength: number,
	AngularDamping: number,
	LinearStrength: number,
	LinearDamping: number,
}

type SocketSnapshot = {
	Enabled: boolean,
	LimitsEnabled: boolean,
}

export type Rig = {
	Character: Model,
	Humanoid: Humanoid,
	RootPart: BasePart,
	LowerTorso: BasePart,
	UpperTorso: BasePart,
	Head: BasePart,
	Joints: { [string]: AnimationConstraint },
	Limbs: { BasePart },
	BallSockets: { BallSocketConstraint },
	Mode: Mode,
	Snapshot: {
		Joints: { [AnimationConstraint]: JointSnapshot },
		Sockets: { [BallSocketConstraint]: SocketSnapshot },
		Collide: { [BasePart]: boolean },
		AutoRotate: boolean,
	}?,
}

local Rig = {}

--[=[
	@prop UPPER_JOINTS { string }
	@within Rig
	@readonly
	Joint names simulated in Muscle mode: `Waist`, `Neck`, both shoulders, elbows and wrists.
]=]
Rig.UPPER_JOINTS = table.freeze({
	"Waist", "Neck",
	"LeftShoulder", "LeftElbow", "LeftWrist",
	"RightShoulder", "RightElbow", "RightWrist",
})

--[=[
	@prop LOWER_JOINTS { string }
	@within Rig
	@readonly
	Joint names kept kinematic in Muscle mode: `Root`, both hips, knees and ankles.
]=]
Rig.LOWER_JOINTS = table.freeze({
	"Root",
	"LeftHip", "LeftKnee", "LeftAnkle",
	"RightHip", "RightKnee", "RightAnkle",
})

--[=[
	Returns whether `character` is an R15 rig on AnimationConstraints (the Avatar Joint Upgrade).
	@function isSupported
	@within Rig
	@param character Instance
	@return boolean
]=]
function Rig.isSupported(character: Instance): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return false
	end
	local lowerTorso = character:FindFirstChild("LowerTorso")
	return lowerTorso ~= nil and lowerTorso:FindFirstChildWhichIsA("AnimationConstraint") ~= nil
end

--[=[
	Collects the joints of `character`. Returns `nil` when the character is not a supported rig
	(see [Rig.isSupported]).

	@function get
	@within Rig
	@param character Model
	@return Rig?
]=]
function Rig.get(character: Model): Rig?
	if not Rig.isSupported(character) then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local lowerTorso = character:FindFirstChild("LowerTorso")
	local upperTorso = character:FindFirstChild("UpperTorso")
	local head = character:FindFirstChild("Head")
	if not (rootPart and lowerTorso and upperTorso and head) then
		return nil
	end

	local joints: { [string]: AnimationConstraint } = {}
	local limbs: { BasePart } = {}
	local sockets: { BallSocketConstraint } = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("AnimationConstraint") then
			joints[descendant.Name] = descendant
		elseif descendant:IsA("BallSocketConstraint") then
			table.insert(sockets, descendant)
		elseif descendant:IsA("BasePart") and descendant ~= rootPart and descendant.Parent == character then
			table.insert(limbs, descendant)
		end
	end
	if not joints.Root then
		return nil
	end

	return {
		Character = character,
		Humanoid = humanoid,
		RootPart = rootPart :: BasePart,
		LowerTorso = lowerTorso :: BasePart,
		UpperTorso = upperTorso :: BasePart,
		Head = head :: BasePart,
		Joints = joints,
		Limbs = limbs,
		BallSockets = sockets,
		Mode = "Kinematic",
		Snapshot = nil,
	}
end

local function snapshot(rig: Rig)
	if rig.Snapshot then
		return
	end
	local joints: { [AnimationConstraint]: JointSnapshot } = {}
	for _, joint in rig.Joints do
		joints[joint] = {
			IsKinematic = joint.IsKinematic,
			AngularStrength = joint.AngularStrength,
			AngularDamping = joint.AngularDamping,
			LinearStrength = joint.LinearStrength,
			LinearDamping = joint.LinearDamping,
		}
	end
	local sockets: { [BallSocketConstraint]: SocketSnapshot } = {}
	for _, socket in rig.BallSockets do
		sockets[socket] = { Enabled = socket.Enabled, LimitsEnabled = socket.LimitsEnabled }
	end
	local collide: { [BasePart]: boolean } = { [rig.RootPart] = rig.RootPart.CanCollide }
	for _, limb in rig.Limbs do
		collide[limb] = limb.CanCollide
	end
	rig.Snapshot = {
		Joints = joints,
		Sockets = sockets,
		Collide = collide,
		AutoRotate = rig.Humanoid.AutoRotate,
	}
end

local function setJoint(joint: AnimationConstraint, kinematic: boolean, strength: number?, damping: number?)
	if not kinematic then
		if strength then
			joint.AngularStrength = strength
		end
		if damping then
			joint.AngularDamping = damping
		end
		joint.LinearStrength = 1
		joint.LinearDamping = 1
	end
	joint.IsKinematic = kinematic
end

local function setSockets(rig: Rig, enabled: boolean)
	local snap = rig.Snapshot
	for _, socket in rig.BallSockets do
		if enabled then
			socket.LimitsEnabled = true
			socket.Enabled = true
		elseif snap then
			local s = snap.Sockets[socket]
			if s then
				socket.Enabled = s.Enabled
				socket.LimitsEnabled = s.LimitsEnabled
			end
		end
	end
end

--[=[
	Puts the rig in `mode`. Takes the snapshot on the first call. The strength and damping
	come from the [Config] (`MuscleStrength` / `MuscleDamping` or `LimpStrength` / `LimpDamping`).

	@function apply
	@within Rig
	@param rig Rig
	@param mode Mode
	@param strength number -- `AngularStrength` for the simulated joints in this mode (ignored for Kinematic).
	@param damping number -- `AngularDamping` for the simulated joints in this mode (ignored for Kinematic).
]=]
function Rig.apply(rig: Rig, mode: Mode, strength: number?, damping: number?)
	snapshot(rig)
	local humanoid = rig.Humanoid
	rig.Mode = mode

	if mode == "Kinematic" then
		for _, joint in rig.Joints do
			setJoint(joint, true)
		end
		setSockets(rig, false)
		for part, canCollide in (rig.Snapshot :: any).Collide do
			if part.Parent then
				part.CanCollide = canCollide
			end
		end
		humanoid.AutoRotate = (rig.Snapshot :: any).AutoRotate
	elseif mode == "Muscle" then
		for _, name in Rig.LOWER_JOINTS do
			local joint = rig.Joints[name]
			if joint then
				setJoint(joint, true)
			end
		end
		for _, name in Rig.UPPER_JOINTS do
			local joint = rig.Joints[name]
			if joint then
				setJoint(joint, false, strength, damping)
			end
		end
		setSockets(rig, true)
		humanoid.AutoRotate = false
	elseif mode == "Limp" then
		for _, joint in rig.Joints do
			setJoint(joint, false, strength, damping)
		end
		setSockets(rig, true)
		humanoid.AutoRotate = false
		rig.RootPart.CanCollide = false
	end
end

--[=[
	Restores every joint, ball socket, collision flag and `AutoRotate` the snapshot recorded,
	and forgets the snapshot. `WalkSpeed` and the Humanoid state flags are owner-side and are
	handled by the [Controller]. Does nothing if no mode was ever applied.

	@function restore
	@within Rig
	@param rig Rig
]=]
function Rig.restore(rig: Rig)
	local snap = rig.Snapshot
	if not snap then
		return
	end
	for joint, s in snap.Joints do
		if joint.Parent then
			joint.AngularStrength = s.AngularStrength
			joint.AngularDamping = s.AngularDamping
			joint.LinearStrength = s.LinearStrength
			joint.LinearDamping = s.LinearDamping
			joint.IsKinematic = s.IsKinematic
		end
	end
	for socket, s in snap.Sockets do
		if socket.Parent then
			socket.Enabled = s.Enabled
			socket.LimitsEnabled = s.LimitsEnabled
		end
	end
	for part, canCollide in snap.Collide do
		if part.Parent then
			part.CanCollide = canCollide
		end
	end
	if rig.Humanoid.Parent then
		rig.Humanoid.AutoRotate = snap.AutoRotate
	end
	rig.Snapshot = nil
	rig.Mode = "Kinematic"
end

return Rig

--!strict
--[=[
	@class Balance
	The balance model behind a stagger: a small, deterministic simulation in the spirit of
	NaturalMotion's Euphoria (the ragdoll behaviour in GTA IV / V and Red Dead). It does not
	know about parts or joints; it turns "you were shoved this hard in this direction" into a
	stream of numbers the [Controller] turns into steps, leaning and a decision.

	The character has a **lurch** (horizontal velocity they are being carried by) and a
	**balance** from 0 to 1. Balance drains while they are lurching. At irregular intervals
	they take a **catch-up step**: a clean step kills part of the lurch and buys some balance
	back, a **stutter** is a half step that buys less and comes sooner, and a **misstep** kicks
	them sideways and costs balance. When the lurch has died down with balance to spare they
	have **recovered**; when balance hits zero they **fall**.

	Everything random comes from a `Random` seeded by the stagger, so the server and the
	simulating client agree on what happens without talking.
]=]

local Config = require(script.Parent.Config)

export type Config = Config.Config

--[=[
	@type Outcome "Staggering" | "Recovered" | "Fell"
	@within Balance
	What [Balance:Step] returns.
]=]
export type Outcome = "Staggering" | "Recovered" | "Fell"

--[=[
	@type Leg "Left" | "Right"
	@within Balance
]=]
export type Leg = "Left" | "Right"

export type Balance = {
	Config: Config,
	Random: Random,
	Time: number,
	Balance: number,
	Momentum: Vector3,
	Direction: Vector3,
	Speed: number,
	Intensity: number,

	Stepping: boolean,
	StepPhase: number,
	StepLeg: Leg,
	StepIsStutter: boolean,
	NextStepAt: number,
	StepEndsAt: number,
	StepsTaken: number,
	Missteps: number,

	Sway: number,

	Step: (self: Balance, dt: number) -> Outcome,
	Disturb: (self: Balance, amount: number, direction: Vector3?) -> (),
	Lean: (self: Balance) -> number,
	ArmRaise: (self: Balance) -> number,
}

local Balance = {}
Balance.__index = Balance

local function flatten(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

--[=[
	Creates a balance model.

	@function new
	@within Balance
	@param config Config
	@param direction Vector3 -- Horizontal direction of the shove (it is flattened and normalised for you).
	@param intensity number -- 1 is the preset as tuned; 0.5 half a shove, 2 a big hit.
	@param seed number -- Seed for the model's `Random`.
	@return Balance
]=]
function Balance.new(config: Config, direction: Vector3, intensity: number, seed: number): Balance
	local flat = flatten(direction)
	if flat.Magnitude < 1e-3 then
		flat = -Vector3.zAxis
	end
	flat = flat.Unit
	intensity = math.max(intensity, 0.05)

	local rng = Random.new(seed)
	local self: Balance = setmetatable({
		Config = config,
		Random = rng,
		Time = 0,
		Balance = math.clamp(config.StartBalance - (intensity - 1) * 0.15, 0.2, 1),
		Momentum = flat * config.LurchSpeed * intensity,
		Direction = flat,
		Speed = config.LurchSpeed * intensity,
		Intensity = intensity,

		Stepping = false,
		StepPhase = 0,
		StepLeg = if rng:NextNumber() < 0.5 then "Left" else "Right",
		StepIsStutter = false,
		NextStepAt = config.StepInterval * 0.4,
		StepEndsAt = 0,
		StepsTaken = 0,
		Missteps = 0,

		Sway = 0,
	} :: any, Balance) :: any
	return self
end

--[=[
	Knocks the model again without restarting it: adds lurch in `direction` (or the current
	direction) and takes `amount` off the balance. The controller feeds bumps into this; you
	can too.

	@method Disturb
	@within Balance
	@param amount number -- Balance to remove, 0 to 1.
	@param direction Vector3? -- Direction of the extra lurch; the lurch added is `amount * LurchSpeed`.
]=]
function Balance.Disturb(self: Balance, amount: number, direction: Vector3?)
	local dir = if direction then flatten(direction) else self.Direction
	if dir.Magnitude > 1e-3 then
		self.Momentum += dir.Unit * amount * self.Config.LurchSpeed
	end
	self.Balance = math.clamp(self.Balance - amount, 0, 1)
end

-- How much the character can still slow down, from 1 (normal) to 0 (none). Below half balance
-- the lurch stops bleeding off, so a character that far gone keeps going until they either fall
-- or step their way back above it.
local function brakeFactor(self: Balance): number
	local low = math.clamp(1 - self.Balance / 0.5, 0, 1)
	return 1 - self.Config.MomentumHold * low
end

local function beginStep(self: Balance)
	local cfg = self.Config
	local rng = self.Random
	local offBalance = 1 - self.Balance

	self.Stepping = true
	self.StepPhase = 0
	self.StepLeg = if self.StepLeg == "Left" then "Right" else "Left"
	self.StepIsStutter = rng:NextNumber() < cfg.StutterChance
	self.StepsTaken += 1

	local duration = cfg.StepDuration * (if self.StepIsStutter then 0.6 else 1)
	self.StepEndsAt = self.Time + duration

	-- A step is where the feet catch up with the body: it eats momentum and buys balance.
	if rng:NextNumber() < cfg.MisstepChance * offBalance then
		-- Misstep: the foot lands wrong. Sideways kick, balance lost, no momentum killed.
		self.Missteps += 1
		local side = self.Direction:Cross(Vector3.yAxis) * (if rng:NextNumber() < 0.5 then 1 else -1)
		self.Momentum += side * cfg.LurchSpeed * 0.35 * rng:NextNumber(0.6, 1)
		self.Balance = math.clamp(self.Balance - 0.15 * rng:NextNumber(0.7, 1.3), 0, 1)
	else
		local keep = cfg.StepMomentumKeep
		local gain = cfg.StepBalanceGain
		if self.StepIsStutter then
			keep = 0.5 + keep * 0.5
			gain *= 0.5
		end
		-- Steps get less effective the faster you are still going: feet can't keep up.
		local overspeed = math.clamp(self.Speed / cfg.LurchSpeed - 1, 0, 1)
		keep = keep + (1 - keep) * overspeed * 0.5
		-- Far off balance the feet only chase the body: the step keeps the momentum.
		keep = keep + (1 - keep) * (1 - brakeFactor(self))
		gain *= (1 - overspeed * 0.5) * rng:NextNumber(0.6, 1.1)
		self.Momentum *= keep
		self.Balance = math.clamp(self.Balance + gain, 0, 1)
	end

	local interval = cfg.StepInterval * rng:NextNumber(0.65, 1.4)
	if self.StepIsStutter then
		interval *= 0.55
	end
	self.NextStepAt = self.Time + math.max(interval, duration)
end

--[=[
	Advances the model by `dt` seconds. Call it every frame on the simulating side.

	@method Step
	@within Balance
	@param dt number
	@return Outcome -- `"Staggering"` while undecided, then `"Recovered"` or `"Fell"` once and for all.
]=]
function Balance.Step(self: Balance, dt: number): Outcome
	local cfg = self.Config
	self.Time += dt

	-- Momentum bleeds on its own (friction), faster once slow.
	local speed = self.Momentum.Magnitude
	local friction = (0.8 + 3 / math.max(speed, 1)) * brakeFactor(self)
	speed = math.max(speed - friction * dt, 0)
	if self.Momentum.Magnitude > 1e-4 then
		self.Direction = self.Momentum.Unit
		self.Momentum = self.Direction * speed
	end
	self.Speed = speed

	-- Balance drains while lurching; a low balance drains faster (leaning too far to catch).
	local speedFactor = 0.3 + speed / cfg.LurchSpeed
	local lowFactor = 1 + math.clamp(0.3 - self.Balance, 0, 0.3) * 2
	self.Balance = math.clamp(self.Balance - cfg.BalanceDrain * speedFactor * lowFactor * dt, 0, 1)

	-- Steps.
	if self.Stepping then
		local duration = cfg.StepDuration * (if self.StepIsStutter then 0.6 else 1)
		self.StepPhase = math.clamp(1 - (self.StepEndsAt - self.Time) / math.max(duration, 1e-3), 0, 1)
		if self.Time >= self.StepEndsAt then
			self.Stepping = false
			self.StepPhase = 0
		end
	end
	if not self.Stepping and self.Time >= self.NextStepAt then
		beginStep(self)
	end

	-- Side to side sway, driven by how off balance we are.
	self.Sway = math.sin(self.Time * 7.3) * (1 - self.Balance) * 0.5 + math.sin(self.Time * 2.1) * 0.15

	-- Decision. A fall needs a couple of failed steps first: before that the model just keeps
	-- leaning at zero balance, which reads as "trying and losing".
	if self.Balance <= 0 and self.Time >= cfg.MinDuration * 0.75 then
		return "Fell"
	end
	if self.Time >= cfg.MinDuration and speed <= cfg.RecoverSpeed and self.Balance >= cfg.RecoverBalance then
		return "Recovered"
	end
	if self.Time >= cfg.MaxDuration then
		return if self.Balance > 0.5 then "Recovered" else "Fell"
	end
	return "Staggering"
end

--[=[
	How far the torso should lean into the lurch right now, in radians.
	@method Lean
	@within Balance
	@return number
]=]
function Balance.Lean(self: Balance): number
	local cfg = self.Config
	local bySpeed = math.clamp(self.Speed / cfg.LurchSpeed, 0, 1.3)
	local byBalance = (1 - self.Balance) * 0.4
	return math.min(bySpeed + byBalance, 1.4) * cfg.MaxLean
end

--[=[
	How far the arms should be out, 0 to 1.
	@method ArmRaise
	@within Balance
	@return number
]=]
function Balance.ArmRaise(self: Balance): number
	return math.clamp((1 - self.Balance) * 1.3 + math.clamp(self.Speed / self.Config.LurchSpeed, 0, 1) * 0.3, 0, 1)
end

return Balance

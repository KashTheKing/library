--!strict
--[=[
	@class Config
	Tuning for a stagger. Every number here is what the balance model, the procedural pose and
	the joint "muscles" read, so a preset is nothing more than a table of these values.

	The defaults describe a shove on an average character. Intensity (passed to [Stagger.Begin])
	scales the starting lurch and how much balance is lost, so one preset covers a range of hits.

	```lua
	Stagger.RegisterPreset("Drunk", Stagger.Presets.Default, {
		BalanceDrain = 0.05,
		MaxDuration = 12,
		StutterChance = 0.7,
	})
	```
]=]

--[=[
	@interface Config
	@within Config
	.StartBalance number -- Balance the character starts with at intensity 1, from 0 (falls at once) to 1 (barely bothered). Intensity above 1 lowers it further. Default `0.6`.
	.BalanceDrain number -- Balance lost per second just from being off balance, scaled by how fast the character is still lurching. Default `0.15`.
	.LurchSpeed number -- Studs per second the character is thrown forward at intensity 1. Default `14`.
	.MaxWalkSpeed number -- Cap on the stumble speed fed to `Humanoid.WalkSpeed`. Default `22`.
	.StepInterval number -- Seconds between catch-up steps, before randomisation. Default `0.34`.
	.StepDuration number -- How long one leg swing lasts. Default `0.22`.
	.StepBalanceGain number -- Balance regained by a clean step. Default `0.14`.
	.StepMomentumKeep number -- Fraction of the lurch that survives a clean step (lower stops sooner). Default `0.7`.
	.MomentumHold number -- How much a low balance stops the lurch slowing down, from 0 (friction and steps always slow it) to 1 (at zero balance it keeps its full speed until the character falls or steps back above half balance). Default `1`.
	.StutterChance number -- Chance a step is a half step: shorter, weaker, closer to the next. This is the "stutter". Default `0.45`.
	.MisstepChance number -- Chance (times how off balance the character is) that a step goes wrong: a sideways kick and a balance loss. Default `0.35`.
	.RecoverSpeed number -- Once the lurch is slower than this many studs per second... Default `2.5`.
	.RecoverBalance number -- ...and balance is above this, the character has recovered. Default `0.6`.
	.MinDuration number -- Never recover before this many seconds, and never fall before three quarters of it. Default `1.2`.
	.MaxDuration number -- Force an outcome after this many seconds: recover if balance is above 0.5, otherwise fall. Default `6`.
	.AirFallTime number -- Seconds with no floor under the character before they fall over (walked off a ledge mid-stagger). Default `0.35`.
	.MaxLean number -- Radians the torso leans into the lurch at full speed. Default `0.55`.
	.ArmRaise number -- Radians the arms come out sideways when balance is low. Default `1.1`.
	.ArmFlail number -- Radians of arm windmilling on top of the raise. Default `0.5`.
	.StepSwing number -- Radians a stepping leg swings forward at the hip. Default `0.7`.
	.KneeBend number -- Radians the knee bends during a step. Default `0.9`.
	.HeadCounter number -- How much the head counter-rotates to stay level (0 none, 1 fully). Default `0.7`.
	.Steering number -- Radians per second the player's walk input can bend the lurch towards where they are walking. `0` ignores input (and turns the controls off for the stagger). Default `2.5`.
	.CatchGain number -- Balance per second a player earns back by walking with the stumble (running it out). Default `0.35`.
	.CatchBrake number -- Extra studs per second per second the lurch slows while they do. Default `4`.
	.TurnSpeed number -- Radians per second the body turns to face the way it is being thrown. `0` (the default) keeps them facing where they were when hit: shoved from the front they stagger backwards. Either way the heading is held so the Humanoid can't swing them round.
	.ReHitBalanceLoss number -- Extra balance lost when hit again mid-stagger, on top of keeping the lower balance and adding the lurches together. Default `0.2`.
	.MuscleStrength number -- `AnimationConstraint.AngularStrength` for the upper body while staggering. Below 1 the arms and torso lag the animation and swing with the body: this is the Euphoria look. Default `0.3`.
	.MuscleDamping number -- `AnimationConstraint.AngularDamping` for the upper body while staggering. Default `0.9`.
	.LimpStrength number -- `AngularStrength` for every joint while ragdolled. 0 is a rag; a little keeps some tone. Default `0.04`.
	.LimpDamping number -- `AngularDamping` while ragdolled. Default `1`.
	.RagdollDuration number -- Seconds to stay ragdolled before standing up on their own. `0` means stay down until [Stagger.Recover] is called. Default `3`.
	.GetUpTime number -- Seconds the get-up animation takes after a ragdoll: arms push, knees come under, then the rise. Default `1.3`.
	.GetUpDuration number -- Seconds a character who recovered on their feet (never fell) stays in `Recovering` before the stagger is over. After a ragdoll the stagger ends with the get-up instead. Default `0.25`.
	.RagdollInAir boolean -- A stagger that starts with no ground under the character ragdolls them instead. Default `true`.
	.DisableControls boolean -- On a player's own client, disable the PlayerModule controls for the duration. Default `true`.
]=]
export type Config = {
	StartBalance: number,
	BalanceDrain: number,
	LurchSpeed: number,
	MaxWalkSpeed: number,
	StepInterval: number,
	StepDuration: number,
	StepBalanceGain: number,
	StepMomentumKeep: number,
	MomentumHold: number,
	StutterChance: number,
	MisstepChance: number,
	RecoverSpeed: number,
	RecoverBalance: number,
	MinDuration: number,
	MaxDuration: number,
	AirFallTime: number,

	MaxLean: number,
	ArmRaise: number,
	ArmFlail: number,
	StepSwing: number,
	KneeBend: number,
	HeadCounter: number,
	Steering: number,
	CatchGain: number,
	CatchBrake: number,
	TurnSpeed: number,
	ReHitBalanceLoss: number,

	MuscleStrength: number,
	MuscleDamping: number,
	LimpStrength: number,
	LimpDamping: number,

	RagdollDuration: number,
	GetUpTime: number,
	GetUpDuration: number,
	RagdollInAir: boolean,
	DisableControls: boolean,
}

local Config = {}

local Default: Config = table.freeze({
	StartBalance = 0.6,
	BalanceDrain = 0.15,
	LurchSpeed = 14,
	MaxWalkSpeed = 22,
	StepInterval = 0.34,
	StepDuration = 0.22,
	StepBalanceGain = 0.14,
	StepMomentumKeep = 0.7,
	MomentumHold = 1,
	StutterChance = 0.45,
	MisstepChance = 0.35,
	RecoverSpeed = 2.5,
	RecoverBalance = 0.6,
	MinDuration = 1.2,
	MaxDuration = 6,
	AirFallTime = 0.35,

	MaxLean = 0.55,
	ArmRaise = 1.1,
	ArmFlail = 0.5,
	StepSwing = 0.7,
	KneeBend = 0.9,
	HeadCounter = 0.7,
	Steering = 2.5,
	CatchGain = 0.35,
	CatchBrake = 4,
	TurnSpeed = 0,
	ReHitBalanceLoss = 0.2,

	MuscleStrength = 0.3,
	MuscleDamping = 0.9,
	LimpStrength = 0.04,
	LimpDamping = 1,

	RagdollDuration = 3,
	GetUpTime = 1.3,
	GetUpDuration = 0.25,
	RagdollInAir = true,
	DisableControls = true,
})
Config.Default = Default

--[=[
	Builds a config from `base` with `overrides` applied on top. Unknown keys and wrong types
	raise an error so typos in presets are caught early.

	@function extend
	@within Config
	@param base Config
	@param overrides { [string]: any }?
	@return Config
]=]
function Config.extend(base: Config, overrides: { [string]: any }?): Config
	local result = table.clone(base)
	if overrides then
		for key, value in overrides do
			local current = (base :: any)[key]
			if current == nil then
				error(`Unknown Stagger config key "{key}"`, 3)
			end
			if typeof(value) ~= typeof(current) then
				error(`Stagger config key "{key}" expects {typeof(current)}, got {typeof(value)}`, 3)
			end
			(result :: any)[key] = value
		end
	end
	return table.freeze(result)
end

--[=[
	@prop Presets { [string]: Config }
	@within Config
	Built in presets, all reachable as `Stagger.Presets`:

	- `Default`: a solid shove.
	- `Light`: a bump; short, usually recovered.
	- `Heavy`: an explosion or a car; long lurch, almost always ends on the floor.
	- `Drunk`: slow drain, lots of half steps, long before anything is decided.
]=]
Config.Presets = {
	Default = Config.Default,
	Light = Config.extend(Config.Default, {
		StartBalance = 0.78,
		LurchSpeed = 9,
		BalanceDrain = 0.12,
		MaxDuration = 3.5,
		MisstepChance = 0.2,
	}),
	Heavy = Config.extend(Config.Default, {
		StartBalance = 0.45,
		LurchSpeed = 22,
		MaxWalkSpeed = 28,
		BalanceDrain = 0.2,
		StepMomentumKeep = 0.78,
		MisstepChance = 0.5,
		MaxLean = 0.75,
		RagdollDuration = 4.5,
	}),
	Drunk = Config.extend(Config.Default, {
		StartBalance = 0.65,
		LurchSpeed = 7,
		BalanceDrain = 0.05,
		StepInterval = 0.45,
		StutterChance = 0.7,
		MisstepChance = 0.4,
		StepMomentumKeep = 0.8,
		RecoverSpeed = 1.5,
		MinDuration = 2,
		MaxDuration = 12,
		MuscleStrength = 0.2,
	}),
} :: { [string]: Config }

return Config

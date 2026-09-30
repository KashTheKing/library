--!strict
--[=[
	@class Stagger

	GTA V / Euphoria style balance loss for R15 characters. Call [Stagger.Begin] on the server and
	the character lurches in a direction, stutter-stepping to get their feet back under them
	while the arms come out and the torso swings with the momentum. Little by little the steps
	catch up, and the character either **recovers** and stands normally again, or runs out of
	balance and **ragdolls**, staying down for a while (or until you call [Stagger.Recover])
	before standing back up.

	It is built on the joints Roblox already gives every character with the Avatar Joint
	Upgrade: `AnimationConstraint` for animation and `BallSocketConstraint` for the limits. No
	joint is ever replaced or added. While staggering the upper body is physically simulated with
	a soft `AngularStrength` (a "muscle"), so it lags behind the procedural pose and reacts to the
	movement the way NaturalMotion's characters do, and when the character falls every joint goes
	limp and the ball sockets take over.

	**Networking.** The server is the authority: it decides when a stagger starts and ends,
	switches the joints (which replicate), and broadcasts state with
	[Packet](/docs/packages/packet). The balance model runs on whoever owns the character's
	physics (the player's client, or the server for NPCs), and the outcome is reported back.
	Controllers are managed by a [Binder](/docs/packages/binder), so every staggering character
	carries the `Staggering` tag for the duration.

	Require the module once on the server and once on every client (a shared `ModuleScript` under
	`ReplicatedStorage.Packages`, which Wally gives you). Requiring it is all the setup there is.

	```lua
	-- Server
	local Stagger = require(ReplicatedStorage.Packages.Stagger)

	explosion.Touched:Connect(function(hit)
		local character = hit.Parent
		if character:FindFirstChildOfClass("Humanoid") then
			local away = (character:GetPivot().Position - explosion.Position)
			Stagger.Begin(character, away, { Preset = "Heavy", Intensity = 1.5 })
		end
	end)

	Stagger.StateChanged:Connect(function(character, state)
		if state == Stagger.State.Ragdoll then
			print(character.Name, "hit the floor")
		end
	end)
	```

	```lua
	-- Client: nothing to call, just make sure it is required somewhere.
	require(ReplicatedStorage.Packages.Stagger)
	```

	Requires **StarterPlayer.AvatarJointUpgrade** to be on (the default for new experiences).
	Characters still rigged with `Motor6D` are skipped with a warning.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Binder = require(script.Parent.Binder)
local Signal = require(script.Parent.Signal)
local Trove = require(script.Parent.Trove)

local Balance = require(script.Balance)
local Config = require(script.Config)
local Controller = require(script.Controller)
local Packets = require(script.Packets)
local Rig = require(script.Rig)

export type Config = Config.Config
export type Controller = Controller.Controller
export type Balance = Balance.Balance
export type Rig = Rig.Rig
export type State = number

--[=[
	@interface BeginOptions
	@within Stagger
	.Preset string? -- Name of a preset from [Stagger.Presets] or [Stagger.RegisterPreset]. Default `"Default"`.
	.Intensity number? -- Scales the shove: 1 is the preset as tuned, 0.5 a nudge, 2 a truck. Default `1`.
	.Seed number? -- Seed for the balance model's randomness (0 to 65535). Random when omitted.
]=]
export type BeginOptions = {
	Preset: string?,
	Intensity: number?,
	Seed: number?,
}

local isServer = RunService:IsServer()

local Stagger = {}

--[=[
	@prop State { Idle: number, Staggering: number, Ragdoll: number, Recovering: number }
	@within Stagger
	@readonly
	The states a character moves through. `Idle` (0) is not staggering. `Staggering` (1) is
	stutter-stepping to regain balance. `Ragdoll` (2) is on the floor, fully simulated.
	`Recovering` (3) is standing back up (or the short settle after recovering on their feet)
	before returning to `Idle`.
]=]
Stagger.State = Controller.STATE

--[=[
	@prop StateNames { [number]: string }
	@within Stagger
	@readonly
	`Stagger.StateNames[Stagger.State.Ragdoll] == "Ragdoll"`.
]=]
Stagger.StateNames = table.freeze({ [0] = "Idle", [1] = "Staggering", [2] = "Ragdoll", [3] = "Recovering" })

--[=[
	@prop TAG string
	@within Stagger
	@readonly
	`"Staggering"`: the CollectionService tag every character carries from [Stagger.Begin] (or
	[Stagger.Ragdoll]) until it is back to Idle.
]=]
Stagger.TAG = "Staggering"

--[=[
	@prop ATTRIBUTE string
	@within Stagger
	@readonly
	`"StaggerState"`: the server writes the numeric state to this attribute on the character so
	other systems (and non-scripted things like UI) can read it.
]=]
Stagger.ATTRIBUTE = "StaggerState"

--[=[
	@prop Presets { [string]: Config }
	@within Stagger
	@readonly
	The built-in presets (`Default`, `Light`, `Heavy`, `Drunk`) plus anything you registered.
	See [Config] for every field.
]=]
Stagger.Presets = Config.Presets

--[=[
	@prop StateChanged Signal<(Model, number, number)>
	@within Stagger
	@readonly
	Fires on every peer when a character changes state: `(character, newState, oldState)`.
]=]
Stagger.StateChanged = Signal.new()

--[=[
	@prop Fell Signal<Model>
	@within Stagger
	@readonly
	Fires on every peer when a character hits the floor (enters `Ragdoll`).
]=]
Stagger.Fell = Signal.new()

--[=[
	@prop Recovered Signal<Model>
	@within Stagger
	@readonly
	Fires on every peer when a character is done: back to `Idle`, on their feet.
]=]
Stagger.Recovered = Signal.new()

--[=[
	@prop Binder Binder<Controller>
	@within Stagger
	@readonly
	The Binder that owns the controllers, for `InstanceBound` / `InstanceUnbound` or
	`GetInstances()`. It is manual-only: do not `Bind` through it yourself.
]=]
Stagger.Binder = Binder.new(Controller :: any, {
	Tags = { Stagger.TAG },
	ManualBindingOnly = true,
	RemoveTagsOnCleanup = true,
	Predicate = function(instance: Instance)
		if not instance:IsA("Model") then
			return false
		end
		local rig = Rig.get(instance)
		return rig ~= nil, rig
	end,
})

local timers: { [Model]: any } = {} -- server: a Trove per character holding the pending timer
local warned: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function getPreset(name: string): Config.Config
	local preset = Config.Presets[name]
	if not preset then
		warn(`Stagger: unknown preset "{name}", using Default`)
		return Config.Default
	end
	return preset
end

local function setAttribute(character: Model, state: number)
	if isServer then
		character:SetAttribute(Stagger.ATTRIBUTE, if state == Controller.STATE.Idle then nil else state)
	end
end

local function fireSignals(character: Model, state: number, previous: number)
	Stagger.StateChanged:Fire(character, state, previous)
	if state == Controller.STATE.Ragdoll then
		Stagger.Fell:Fire(character)
	elseif state == Controller.STATE.Idle and previous ~= Controller.STATE.Idle then
		Stagger.Recovered:Fire(character)
	end
end

-- Applies a state on this peer: binds/unbinds the controller and forwards to it.
local function applyLocal(character: Model, state: number, payload: Controller.Payload?)
	local controller = Stagger.Binder:GetBinding(character)
	local previous = if controller then controller.State else Controller.STATE.Idle

	if state == Controller.STATE.Idle then
		if controller then
			controller:SetState(state)
			Stagger.Binder:Unbind(character)
		end
		fireSignals(character, state, previous)
		return
	end

	if not controller then
		local ok, result = pcall(function()
			return Stagger.Binder:Bind(character)
		end)
		if not ok or not result then
			-- Clients can get a state before a streamed-in character has all its joints; the
			-- server drives NPCs and already warned for real unsupported rigs, so stay quiet here.
			if isServer and not warned[character] then
				warned[character] = true
				warn(`Stagger: {character:GetFullName()} is not an R15 AnimationConstraint rig (Avatar Joint Upgrade); skipping`)
			end
			return
		end
		controller = result
	end
	controller:SetState(state, payload)
	fireSignals(character, state, previous)
end

--------------------------------------------------------------------------------------------------
-- Server
--------------------------------------------------------------------------------------------------

local setServerState: (character: Model, state: number, payload: Controller.Payload?) -> ()

local function clearTimer(character: Model)
	local t = timers[character]
	if t then
		t:Clean()
		timers[character] = nil
	end
end

local function startTimer(character: Model, seconds: number, callback: () -> ())
	clearTimer(character)
	local t = Trove.new()
	timers[character] = t
	t:Add(task.delay(seconds, function()
		timers[character] = nil
		callback()
	end))
end

local function onOutcome(controller: Controller.Controller, outcome: Balance.Outcome)
	-- NPC driven by the server: the balance model decided.
	if outcome == "Fell" then
		setServerState(controller.Character, Controller.STATE.Ragdoll)
	else
		setServerState(controller.Character, Controller.STATE.Recovering)
	end
end

local function watchCharacter(controller: Controller.Controller)
	local character = controller.Character
	local trove = controller.Trove
	trove:Connect(controller.Humanoid.Died, function()
		-- Leave the joints as they are: a limp rig is exactly what a dead one should be, and
		-- Roblox's own death handling takes it from here.
		clearTimer(character)
		local c = Stagger.Binder:GetBinding(character)
		if c then
			local previous = c.State
			c:SetState(Controller.STATE.Idle)
			Stagger.Binder:Unbind(character)
			setAttribute(character, Controller.STATE.Idle)
			fireSignals(character, Controller.STATE.Idle, previous)
			Packets.State:Fire(character, Controller.STATE.Idle, Vector3.zero, 0, 0, "")
		end
	end)
	trove:Connect(character.AncestryChanged, function()
		if not character:IsDescendantOf(game) then
			clearTimer(character)
			Stagger.Binder:Unbind(character)
		end
	end)
end

function setServerState(character: Model, state: number, payload: Controller.Payload?)
	local existing = Stagger.Binder:GetBinding(character)
	local wasBound = existing ~= nil
	local previous = if existing then existing.State else Controller.STATE.Idle
	if state == previous and state ~= Controller.STATE.Staggering then
		return
	end

	clearTimer(character)
	applyLocal(character, state, payload)
	local controller = Stagger.Binder:GetBinding(character)
	if state ~= Controller.STATE.Idle and not controller then
		return -- unsupported rig; applyLocal warned
	end

	if controller then
		if not wasBound then
			controller.OnOutcome = onOutcome
			watchCharacter(controller)
		end
		local rig = controller.Rig
		local cfg = controller.Config
		if state == Controller.STATE.Staggering then
			Rig.apply(rig, "Muscle", cfg.MuscleStrength, cfg.MuscleDamping)
		elseif state == Controller.STATE.Ragdoll then
			Rig.apply(rig, "Limp", cfg.LimpStrength, cfg.LimpDamping)
			if cfg.RagdollDuration > 0 then
				startTimer(character, cfg.RagdollDuration, function()
					setServerState(character, Controller.STATE.Recovering)
				end)
			end
		elseif state == Controller.STATE.Recovering then
			-- From the floor: the upper body stays soft so it swings through the get-up, and the
			-- stagger is over as soon as the get-up is (the driver hands control back right then).
			local fromFloor = previous == Controller.STATE.Ragdoll
			if fromFloor then
				Rig.apply(rig, "Muscle", cfg.MuscleStrength * 2, cfg.MuscleDamping)
			else
				Rig.apply(rig, "Kinematic")
			end
			startTimer(character, if fromFloor then cfg.GetUpTime + 0.2 else cfg.GetUpDuration, function()
				setServerState(character, Controller.STATE.Idle)
			end)
		end
		-- NPCs are driven by the server, so the server has to simulate them too. Simulated joints
		-- split the rig into several assemblies and Roblox hands those to the nearest player, whose
		-- copy of the Humanoid still thinks it is standing and flings the limp body into the sky.
		if controller.IsDriver then
			Rig.ownByServer(rig)
		end
	end
	if state == Controller.STATE.Idle and existing then
		Rig.restore(existing.Rig)
	end

	setAttribute(character, state)
	local p = payload
	Packets.State:Fire(
		character,
		state,
		if p then p.Direction else Vector3.zero,
		if p then p.Seed else 0,
		if p then p.Intensity else 0,
		if p then p.Preset else ""
	)
end

local function makePayload(direction: Vector3?, options: BeginOptions?): Controller.Payload
	local opts: BeginOptions = options or {}
	local presetName = opts.Preset or "Default"
	local dir = direction or Vector3.zero
	if dir.Magnitude < 1e-3 then
		dir = -Vector3.zAxis
	end
	return {
		Direction = Vector3.new(dir.X, 0, dir.Z).Unit,
		Seed = opts.Seed or math.random(0, 65535),
		Intensity = opts.Intensity or 1,
		Preset = presetName,
		Config = getPreset(presetName),
	}
end

--[=[
	Starts a stagger. The character lurches along `direction` (flattened to the ground) and
	begins stutter-stepping. Whether they recover or fall is up to the balance model, tuned by
	the preset and `Intensity`. Calling it on a character that is already staggering hits them
	again: a fresh lurch from the new direction. Calling it on a ragdolled character does nothing.

	@server
	@function Begin
	@within Stagger
	@param character Model -- An R15 character on AnimationConstraints (player or NPC).
	@param direction Vector3? -- World direction of the shove. Defaults to the character's forward.
	@param options BeginOptions?
	@return boolean -- `false` if the character is not a supported rig, is dead, or is ragdolled.
]=]
function Stagger.Begin(character: Model, direction: Vector3?, options: BeginOptions?): boolean
	assert(isServer, "Stagger.Begin can only be called on the server")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	if not Rig.isSupported(character) then
		if not warned[character] then
			warned[character] = true
			warn(`Stagger: {character:GetFullName()} is not an R15 AnimationConstraint rig (Avatar Joint Upgrade); skipping`)
		end
		return false
	end
	local state = Stagger.GetState(character)
	if state == Controller.STATE.Ragdoll then
		return false
	end
	local rootPart = humanoid.RootPart
	local payload = makePayload(direction or (if rootPart then rootPart.CFrame.LookVector else nil), options)
	setServerState(character, Controller.STATE.Staggering, payload)
	return Stagger.GetState(character) == Controller.STATE.Staggering
end

--[=[
	Drops the character straight into the ragdoll, skipping the stagger (or cutting one short).
	Uses the preset's `RagdollDuration` to decide when they get up; `0` means they stay down
	until [Stagger.Recover].

	@server
	@function Ragdoll
	@within Stagger
	@param character Model
	@param options BeginOptions? -- Only `Preset` is used (for the ragdoll tuning) when the character was Idle.
	@return boolean -- `false` if the character is not a supported rig or is dead.
]=]
function Stagger.Ragdoll(character: Model, options: BeginOptions?): boolean
	assert(isServer, "Stagger.Ragdoll can only be called on the server")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or not Rig.isSupported(character) then
		return false
	end
	local payload = if Stagger.GetState(character) == Controller.STATE.Idle then makePayload(nil, options) else nil
	setServerState(character, Controller.STATE.Ragdoll, payload)
	return Stagger.GetState(character) == Controller.STATE.Ragdoll
end

--[=[
	Ends the stagger or ragdoll: the character stands up now (`Recovering`), then returns to
	`Idle` after the preset's `GetUpDuration`. Does nothing for an Idle character.

	@server
	@function Recover
	@within Stagger
	@param character Model
]=]
function Stagger.Recover(character: Model)
	assert(isServer, "Stagger.Recover can only be called on the server")
	local state = Stagger.GetState(character)
	if state == Controller.STATE.Idle or state == Controller.STATE.Recovering then
		return
	end
	setServerState(character, Controller.STATE.Recovering)
end

--[=[
	Cancels everything immediately: joints restored, controls back, straight to `Idle` with no
	get-up. Use it when something else takes over the character (a cutscene, a seat, a teleport).

	@server
	@function Stop
	@within Stagger
	@param character Model
]=]
function Stagger.Stop(character: Model)
	assert(isServer, "Stagger.Stop can only be called on the server")
	if Stagger.GetState(character) ~= Controller.STATE.Idle then
		setServerState(character, Controller.STATE.Idle)
	end
end

--[=[
	Registers (or replaces) a preset for [Stagger.Begin]'s `Preset` option. Register the same
	presets on the server and the client, since the client needs the tuning to run the balance
	model for its own character. Unknown keys and wrong types raise an error.

	```lua
	Stagger.RegisterPreset("Slippery", Stagger.Presets.Default, { MisstepChance = 0.8, StepMomentumKeep = 0.85 })
	```

	@function RegisterPreset
	@within Stagger
	@param name string
	@param base Config -- A preset to start from, usually `Stagger.Presets.Default`.
	@param overrides { [string]: any }? -- Fields to change; see [Config].
	@return Config -- The frozen preset.
]=]
function Stagger.RegisterPreset(name: string, base: Config.Config, overrides: { [string]: any }?): Config.Config
	local preset = Config.extend(base, overrides)
	Config.Presets[name] = preset
	return preset
end

--[=[
	@function GetState
	@within Stagger
	@param character Model
	@return number -- One of [Stagger.State]; `Idle` for anything that is not staggering.
]=]
function Stagger.GetState(character: Model): number
	local controller = Stagger.Binder:GetBinding(character)
	return if controller then controller.State else Controller.STATE.Idle
end

--[=[
	@function IsStaggering
	@within Stagger
	@param character Model
	@return boolean -- `true` in any state other than `Idle`.
]=]
function Stagger.IsStaggering(character: Model): boolean
	return Stagger.GetState(character) ~= Controller.STATE.Idle
end

--[=[
	The live [Controller] for a character, or `nil` when it is Idle. On the driving peer its
	`Balance` field is the running [Balance] model, handy for debugging or for feeding extra
	bumps with `Balance:Disturb`.

	@function GetController
	@within Stagger
	@param character Model
	@return Controller?
]=]
function Stagger.GetController(character: Model): Controller.Controller?
	return Stagger.Binder:GetBinding(character)
end

--[=[
	@function GetCharacters
	@within Stagger
	@return { Model } -- Every character currently not Idle.
]=]
function Stagger.GetCharacters(): { Model }
	return Stagger.Binder:GetInstances() :: any
end

--[=[
	@function IsSupported
	@within Stagger
	@param character Instance
	@return boolean -- Whether the character is an R15 rig on AnimationConstraints.
]=]
Stagger.IsSupported = Rig.isSupported

--------------------------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------------------------

if isServer then
	Packets.Report.OnServerEvent:Connect(function(player: Player, character: Instance?, state: number)
		if not character or player.Character ~= character or not character:IsA("Model") then
			return
		end
		local controller = Stagger.Binder:GetBinding(character)
		if not controller or controller.State ~= Controller.STATE.Staggering then
			return
		end
		if state == Controller.STATE.Ragdoll or state == Controller.STATE.Recovering then
			setServerState(character, state)
		end
	end)

	-- Late joiners get the current picture (they only need to drive their own character, but
	-- the state and tag are useful to everyone).
	Players.PlayerAdded:Connect(function(player)
		for _, character in Stagger.Binder:GetInstances() do
			local controller = Stagger.Binder:GetBinding(character)
			if controller then
				Packets.State:FireClient(player, character, controller.State, controller.Direction, controller.Seed, controller.Intensity, controller.Preset)
			end
		end
	end)
else
	Packets.State.OnClientEvent:Connect(function(character: Instance?, state: number, direction: Vector3, seed: number, intensity: number, preset: string)
		if not character or not character:IsA("Model") then
			return
		end
		local payload: Controller.Payload? = nil
		if preset ~= "" then
			payload = {
				Direction = direction,
				Seed = seed,
				Intensity = intensity,
				Preset = preset,
				Config = getPreset(preset),
			}
		end
		applyLocal(character, state, payload)
		local controller = Stagger.Binder:GetBinding(character)
		if controller and not controller.OnOutcome then
			controller.OnOutcome = function(c, outcome)
				Packets.Report:Fire(c.Character, if outcome == "Fell" then Controller.STATE.Ragdoll else Controller.STATE.Recovering)
			end
			controller.Trove:Connect(character.AncestryChanged, function()
				if not character:IsDescendantOf(game) then
					Stagger.Binder:Unbind(character)
				end
			end)
		end
	end)
end

return Stagger

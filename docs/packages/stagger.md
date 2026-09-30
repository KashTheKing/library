---
title: Stagger
sidebar_label: Stagger
sidebar_position: 19
description: "GTA V / Euphoria style balance loss for R15: stutter-step to recover or ragdoll, on Roblox's AnimationConstraint rigs."
---

# Stagger

<div className="library-links">

[API reference](/api/Stagger) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/Stagger) [Wally page](https://wally.run/package/kashtheking/stagger) [Play the showcase](https://www.roblox.com/games/112167466607045/Stagger-Ragdoll-Test)

</div>

<span className="library-card-meta">@0.1.1</span>

**GTA V / Euphoria style balance loss for R15: stutter-step to recover or ragdoll, on Roblox's AnimationConstraint rigs.**

Call `Stagger.Begin` on the server and the character lurches in a direction, taking quick, irregular catch-up steps to get their feet back under them while the arms come out and the torso swings with the momentum. Each step kills some of the lurch and buys some balance back; a half step (the stutter) buys less, a misstep kicks them sideways. Little by little they either **recover** and stand normally, or run out of balance and **ragdoll**, staying down for a while before standing back up. It is modelled on NaturalMotion's Euphoria, the behaviour behind the staggering in GTA IV / V and Red Dead Redemption.

It uses only the joints Roblox already gives every character with the [Avatar Joint Upgrade](https://devforum.roblox.com/t/avatar-joint-upgrade-for-physically-simulated-character-movement-is-now-live/4298561): `AnimationConstraint` for the animation and the `BallSocketConstraint` limits next to it. **No joint is replaced or added.** While staggering the upper body is physically simulated with a soft `AngularStrength` (a "muscle") so it lags the procedural pose and reacts to movement, and the root and legs stay kinematic so the Humanoid keeps the character on its feet. When they fall every limb goes limp and the ball sockets do the rest; only the `Root` joint stays rigid so the `HumanoidRootPart` (and the camera) rides along with the hips.

## Try it

[**Stagger Ragdoll Test**](https://www.roblox.com/games/112167466607045/Stagger-Ragdoll-Test) is a playable showcase with wrecking balls, a spinning sweeper, a crate cannon, a fall tower and damage pads. Press **R** (or **Y** on a gamepad, or the on-screen button) to lose your balance whenever you like.

## Use it when

- You want hits, explosions, shoves or slips to look like a person losing their footing, not a switch between "animating" and "ragdoll".
- You already run the new avatar joints and want a ragdoll that plugs into them instead of rebuilding the rig.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/stagger`.
3. Press download and choose **Shared module**.

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
Stagger = "kashtheking/stagger@0.1.1"
```

Requires **StarterPlayer.AvatarJointUpgrade** to be on (the default for new experiences). Characters still rigged with `Motor6D` are skipped with a warning.

## Example

Require the module once on the server and once on every client. Requiring it is the setup.

```lua
-- Server
local Stagger = require(ReplicatedStorage.Packages.Stagger)

explosion.Touched:Connect(function(hit)
	local character = hit.Parent
	if character:FindFirstChildOfClass("Humanoid") then
		local away = character:GetPivot().Position - explosion.Position
		Stagger.Begin(character, away, { Preset = "Heavy", Intensity = 1.5 })
	end
end)

Stagger.Fell:Connect(function(character)
	print(character.Name, "hit the floor")
end)

-- elsewhere
Stagger.Ragdoll(character)   -- straight to the floor, no stagger
Stagger.Recover(character)   -- stand up now
Stagger.Stop(character)      -- cancel: joints restored, no get-up
```

```lua
-- Client: nothing to call
require(ReplicatedStorage.Packages.Stagger)
```

## How it works

**Authority.** The server owns the state (`Idle`, `Staggering`, `Ragdoll`, `Recovering`), switches the joints (`IsKinematic`, `AngularStrength`, `AngularDamping`, ball socket limits, root collision), writes the `StaggerState` attribute and the `Staggering` tag, and broadcasts every change with [Packet](./packet.md).

**Simulation.** The balance model runs on whoever owns the character's physics: the player's client for their own character, the server for NPCs. Every `Heartbeat` it advances the model, drives the Humanoid with `Humanoid:Move` pulses (moving only while a foot is in the air, which is the "step forward little by little"), and every `PreSimulation` it multiplies the procedural pose (lean, sway, arms out and flailing, leg swing, head counter-rotation) into each joint's `Transform`, the way Roblox recommends layering procedural animation on `AnimationConstraint`. When the model decides, the client reports the outcome with a second packet and the server applies it. `Transform` never replicates, so every other client runs its own copy of the same seeded model just to draw the pose, while the movement itself arrives as replicated physics.

**Momentum and re-hits.** Below half balance the lurch stops slowing down (`MomentumHold`), so a character that far gone keeps going until they fall or step back above it. A side-on hit turns the body (`TurnAmount`) so the stumble goes front or back first, and the feet step whichever way the body is going. Hit again mid-stagger and it only gets worse: the lower balance is kept, `ReHitBalanceLoss` comes off on top, and the two lurches add up.

**Determinism.** Everything random is seeded per stagger, so the server and the client agree without talking.

**Lifecycle.** Controllers are bound to characters with [Binder](./binder.md). A dead character is unbound without restoring its joints, so the limp rig becomes the corpse and Roblox's own death handling takes over.

## Presets and tuning

`Stagger.Presets` ships `Default`, `Light`, `Heavy` and `Drunk`. Register your own on both sides:

```lua
Stagger.RegisterPreset("Slippery", Stagger.Presets.Default, {
	MisstepChance = 0.8,
	StepMomentumKeep = 0.85,
	RagdollDuration = 0, -- stay down until Stagger.Recover
})
```

### Recipe: too weak to stand

A stagger that never recovers: steps barely help, balance drains until the character falls, and the ragdoll stays down until you call `Stagger.Recover`. Register it on the server and the client:

```lua
Stagger.RegisterPreset("Suspended", Stagger.Presets.Default, {
	StartBalance = 0.85,
	LurchSpeed = 7,
	BalanceDrain = 0.2, -- lower = longer struggle
	StepBalanceGain = 0.01,
	RecoverBalance = 2, -- unreachable: never recovers
	MaxDuration = math.huge,
	RagdollDuration = 0,
})
```

For legs that visibly give out, lower `Humanoid.HipHeight` and fold the knees on the owning client as balance drops. Read it from `Stagger.GetController(character).Balance.Balance` while the state is `Staggering`, and multiply the extra bend into the hip, knee and ankle `Transform`s in `PreSimulation`.

Every field is documented on the [Config](/api/Config) page: balance drain and step timing, lean and flail amounts, muscle and limp strengths, ragdoll and get-up durations, and whether the player's controls are disabled.

## Dependencies

[Packet](./packet.md), [Binder](./binder.md) and sleitnick's [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) and [Signal](https://sleitnick.github.io/RbxUtil/api/Signal/). Wally installs them for you.

## API

Every function, property and type is documented on the [Stagger API page](/api/Stagger), with the [Controller](/api/Controller), [Balance](/api/Balance), [Rig](/api/Rig) and [Config](/api/Config) pages for the pieces underneath, all generated from the doc comments in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

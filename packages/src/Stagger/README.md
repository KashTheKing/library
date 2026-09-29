# Stagger

GTA V / Euphoria style balance loss for R15 characters. Shove a character and they lurch off, stutter-stepping to get their feet back under them while the arms come out and the torso swings with the momentum. Little by little the steps catch up and they either recover and stand normally again, or run out of balance and ragdoll, staying down for a moment before standing back up.

Built on the joints Roblox already gives every character with the **Avatar Joint Upgrade**: `AnimationConstraint` for the animation and `BallSocketConstraint` for the limits. No joint is replaced or added. While staggering the upper body runs as soft "muscles" (`IsKinematic = false` with a low `AngularStrength`) so it lags the procedural pose and reacts to the movement; when the character falls every joint goes limp and the ball sockets take over.

Server authoritative, networked with [Packet](../Packet), controllers managed with [Binder](../Binder).

Documentation and API reference: **https://kashtheking.com/library/docs/packages/stagger/**

## Installation

### Studio Wally

Using the [Studio Wally plugin](../../../plugins/studio-wally):

1. Open the widget
2. Search `kashtheking/stagger`
3. Click the download button and choose "Shared module"

### Wally

Add this to the `[dependencies]` section of your `wally.toml`:

```toml
Stagger = "kashtheking/stagger@0.1.0"
```

## Usage

Require the module once on the server and once on every client. That is the whole setup.

```lua
-- Server
local Stagger = require(ReplicatedStorage.Packages.Stagger)

Stagger.Begin(character, shoveDirection, { Preset = "Heavy", Intensity = 1.5 })
Stagger.Ragdoll(character)   -- skip the stagger, straight to the floor
Stagger.Recover(character)   -- stand up now
Stagger.Stop(character)      -- cancel everything, no get-up

Stagger.Fell:Connect(function(character) end)
Stagger.Recovered:Connect(function(character) end)
```

```lua
-- Client
require(ReplicatedStorage.Packages.Stagger)
```

Requires `StarterPlayer.AvatarJointUpgrade` to be enabled (the default for new experiences). Characters still rigged with `Motor6D` are skipped with a warning.

## Tests

`lune-tests/run.sh` runs an end-to-end suite in [Lune](https://lune-org.github.io/docs): two peers, a fake Packet bridge, a synthetic Avatar Joint Upgrade rig and whole staggers driven frame by frame. It is not part of the Wally package.

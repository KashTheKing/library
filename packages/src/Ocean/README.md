# Ocean

The open-source core of [Infinite Ocean](https://kashtheking.com/infinite-ocean/): an infinite Gerstner-wave sea for Roblox on `EditableMesh`, synced between server and clients, with a weather API (named wave and colour sets cross-faded in time and space), zones, obstacles that calm the water, dry regions, water events and surface queries. MIT licensed.

Documentation, tutorial and API reference: **https://kashtheking.com/infinite-ocean/**

The **Infinite Ocean Studio plugin** (installer, live Edit-mode preview, settings panel, presets) and its **addons** (Buoyancy, Swimming, Drowning, WaterSplash, Weather, Zones, DevTools) are proprietary and not part of this package: get the plugin on the [Creator Store](https://create.roblox.com/store/asset/76752250508724/Infinite-Ocean). Without the Buoyancy addon the sea is visuals, queries and events only.

## Installation

### Studio Wally

Using the [Studio Wally plugin](../../../plugins/studio-wally):

1. Open the widget
2. Search `kashtheking/ocean`
3. Click the download button and choose "Shared module"

### Wally

Add this to the `[dependencies]` section of your `wally.toml`:

```toml
Ocean = "kashtheking/ocean@1.1.0"
```

### Infinite Ocean plugin

The plugin installs the same module at `ReplicatedStorage.Ocean` with one click and gives you a settings panel for it.

## Use

Start the sea once on the server and once on every client. `Init` is safe to call more than once.

```lua
-- a Script (server) and a LocalScript (client), both:
local Ocean = require(game.ReplicatedStorage.Packages.Ocean)
Ocean.Init()
```

```lua
-- server
Ocean:CreateWeather("Storm", Ocean.Presets.Ocean["Pirate Seas"])
Ocean:SetWeather("Storm", 20)          -- cross-fade the whole sea over 20 s

-- either side
local y = Ocean:GetHeight(position)    -- surface Y right now
Ocean.EnteredWater:Connect(function(instance) end)
```

Settings are attributes on the module (`Ocean.Settings.List` is the spec). Tag a part `OceanObstacle` to calm the water against it, `OceanDry` for an interior with no water, `OceanTrack` for water events.

The experience must allow `EditableMesh` (Experience Settings) for the wave mesh; without it the sea falls back to a flat surface.

## Support

[Discord](https://discord.gg/6HYgCk22eD), or **@KashTheKing** on Roblox, YouTube and X.

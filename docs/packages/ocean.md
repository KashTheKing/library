---
title: Ocean
sidebar_label: Ocean
sidebar_position: 12
description: "The Infinite Ocean module: an infinite Gerstner-wave sea on EditableMesh, synced server and client, with weather, zones, water queries and events."
---

# Ocean

<div className="library-links">

[API reference](/api/Ocean) [Full documentation](https://kashtheking.com/infinite-ocean/) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/Ocean) [Wally page](https://wally.run/package/kashtheking/ocean)

</div>

<span className="library-card-meta">v1.0.2</span>

**The Infinite Ocean module: an infinite Gerstner-wave sea on `EditableMesh`, synced between server and clients.**

Ocean draws an endless animated surface that follows the camera and runs the same wave function on the server, so physics and queries agree with what players see. It carries a weather API (named sets of waves and colours, cross-faded over time, for the whole sea or for zones), obstacles that calm the water, dry regions that keep it out, water events and surface queries.

This is the open-source core of the [Infinite Ocean plugin](../plugins/infinite-ocean.md). The plugin adds the installer, the settings panel, presets with lighting, a live Edit-mode preview and the addons (Buoyancy, Swimming, Drowning, WaterSplash, Weather, Zones, DevTools). The package on its own is the sea, its weather and its queries.

## Use it when

- You want open water in an experience and are happy to configure it from scripts or attributes.
- You need the surface height, depth or normal at a point on both server and client.
- You want to drive sea state (calm, storm, a sheltered bay) from your own weather or game logic.

If you would rather click than script, get the plugin instead: it installs this same module.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/ocean`.
3. Press download and choose **Shared module**.

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
Ocean = "kashtheking/ocean@1.0.2"
```

### Infinite Ocean plugin

The [plugin](../plugins/infinite-ocean.md) installs the module at `ReplicatedStorage.Ocean` with one click and starts it for you.

## Start it

Installed from Wally the module sits in `ReplicatedStorage.Packages`, so start it yourself: once on the server and once on every client. `Init` is safe to call more than once.

```lua
-- in a Script (server) and in a LocalScript (client)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ocean = require(ReplicatedStorage.Packages.Ocean)
Ocean.Init()
```

The experience has to allow `EditableMesh` (Experience Settings) for the wave mesh. Without it the sea falls back to a flat surface at `SeaLevel`; `Ocean.Waves.MeshAvailable()` tells you which case you are in.

## Examples

```lua
-- server: a storm rolls in over 30 seconds
Ocean:CreateWeather("Storm", Ocean.Presets.Ocean["Pirate Seas"])
Ocean:SetWeather("Storm", 30)

-- a calm bay inside it
Ocean:CreateZone("Bay", { Position = Vector3.new(0, 0, 2000), Radius = 800, Weather = "Default" })

-- either side: where is the water?
local y = Ocean:GetHeight(position)
local under = Ocean:IsUnderWater(position)

-- water events for characters and tagged instances
Ocean.EnteredWater:Connect(function(instance) end)

-- settings are attributes on the module; Set validates and clamps
Ocean.Settings.Set("WaveHeight", 2)
```

Tag a part `OceanObstacle` to calm the water around it, `OceanDry` for an interior with no water, `OceanTrack` for water events, `OceanZone` for an area with its own sea.

## Dependencies

None.

## API

Every method, property and type is documented on the [Ocean API page](/api/Ocean) and its companions ([Settings](/api/Settings), [Presets](/api/Presets), [Weather](/api/Weather), [Zones](/api/Zones), [Regions](/api/Regions), [Tracker](/api/Tracker), [Waves](/api/Waves)), generated from the doc comments in the [source](https://github.com/KashTheKing/library/tree/main/packages/src/Ocean). Guides, the settings reference and the tutorial live on the [Infinite Ocean site](https://kashtheking.com/infinite-ocean/).

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

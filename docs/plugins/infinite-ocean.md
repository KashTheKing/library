---
title: Infinite Ocean
sidebar_position: 5
description: Infinite Gerstner-wave ocean for Roblox with buoyancy, swimming and weather.
---

# Infinite Ocean

<div className="library-links">

[Full documentation](https://kashtheking.com/infinite-ocean/) [Get it on the Creator Store](https://create.roblox.com/store/asset/76752250508724/Infinite-Ocean) [Ocean package](../packages/ocean.md) [Ocean module source](https://github.com/KashTheKing/library/tree/main/packages/src/Ocean) [This page's source](https://github.com/KashTheKing/library/tree/main/plugins/infinite-ocean)

</div>

<span className="library-card-meta">paid plugin · MIT module</span>

**An infinite, animated, fully scriptable sea for Roblox, built on `EditableMesh`.**

Server and clients run the same wave function off `workspace:GetServerTimeNow()`, so physics and visuals stay in phase and only settings ever replicate. It is *just the ocean*: no lighting or weather effects forced on you, and a weather API so your own systems can drive the sea state.

- Camera-following wave mesh with distance LOD
- Vertex-tinted water that darkens at night, animated crest foam near the camera
- Real buoyancy and swim physics for tagged parts and characters
- Weather types and zones, cross-faded in time and space, deterministic on both sides
- Ocean, Visual and Physics presets (Calm/Storm, Tropical/Realistic, Floaty/Submarine and more), plus your own saved presets
- Live Edit-mode preview, in-Studio settings panel with colour picker, float and obstacle placement tools
- Fast/Regular/Realistic quality tiers, custom water and foam textures and materials

The plugin is paid and closed-source. The `Ocean` module it installs is MIT licensed, open source in this library at [packages/src/Ocean](https://github.com/KashTheKing/library/tree/main/packages/src/Ocean), and installable on its own as the Wally package [`kashtheking/ocean`](../packages/ocean.md).

## How to use

1. Install the plugin and open the **Ocean** panel.
2. Press **Install** to add the `Ocean` module to `ReplicatedStorage` (it bootstraps the server and every client automatically).
3. Tune settings from the panel, or drive them from your own scripts through the `Ocean` API.

## Where the docs are

Infinite Ocean has its own site with a no-scripting guide, a tutorial, the plugin guide and the full API reference: **[kashtheking.com/infinite-ocean](https://kashtheking.com/infinite-ocean/)**. This page is only a pointer so the plugin is listed with the rest of the library.

## Help

[Discord](https://discord.gg/6HYgCk22eD) · [Help & contact](../support.md)

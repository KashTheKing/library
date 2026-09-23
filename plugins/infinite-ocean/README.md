# Infinite Ocean
Infinite Gerstner-wave ocean for Roblox, built on `EditableMesh`.

Server and clients run the same wave function off `workspace:GetServerTimeNow()`, so physics and
visuals stay in phase and only settings ever replicate. It's *just the ocean*: no lighting, no
weather effects forced on you. It exposes a weather API so your own systems can drive the sea
state.

- Camera-following wave mesh with distance LOD
- Vertex-tinted water that darkens at night, animated crest foam near the camera
- Real buoyancy and swim physics for tagged parts and characters
- Weather types and zones, cross-faded in time and space, deterministic on both sides
- Ocean, Visual, and Physics presets (Calm/Storm, Tropical/Realistic, Floaty/Submarine, etc.),
  plus your own saved presets
- Live Edit-mode preview, in-Studio settings panel with color picker, float/obstacle placement
  tools
- Fast/Regular/Realistic quality tiers, custom water/foam textures and materials

The plugin is paid and closed-source; the underlying `Ocean` module it installs is MIT-licensed
and open source.

## Installation
Source and build instructions: https://github.com/KashTheKing/ocean

## How to use:
1. Install the plugin and open the *Ocean* panel.
2. Press **Install** to add the `Ocean` module to `ReplicatedStorage` (bootstraps server and
   client automatically).
3. Tune settings from the panel, or drive them from your own scripts via the `Ocean` API.

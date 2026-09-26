---
title: Installing packages
sidebar_position: 1
description: Install any library package with Wally, the Studio Wally plugin, or a Packager block.
---

# Installing packages

Every package in the library is published to [Wally](https://wally.run), the Roblox package manager, under the `kashtheking` scope. There are three ways to get one into your experience. Pick by how you work, not by the package: all of them end with the same module in `ReplicatedStorage.Packages`.

| You work in | Use | Tooling needed |
| --- | --- | --- |
| Roblox Studio only | [Studio Wally plugin](#studio-wally) | The plugin |
| A Rojo project with a file system | [Wally CLI](#wally) | Rokit (or Aftman) + Wally + Rojo |
| Studio, and you want a whole system | [Packager](#packager-building-blocks) | The plugin |

## Studio Wally

The [Studio Wally plugin](../plugins/studio-wally.md) is a Wally client that runs inside Studio.

1. Install [Studio Wally](https://create.roblox.com/store/asset/133519889832441/Studio-Wally-With-package-types) from the Creator Store and open its widget.
2. Search the package by scope and name. Every [package page](../packages/index.md) shows the exact string, for example `kashtheking/binder`.
3. Press download and pick **Shared module**. The package and its dependencies are placed in `ReplicatedStorage.Packages`.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Binder = require(ReplicatedStorage.Packages.Binder)
```

The plugin re-exports the package's types, so strict-mode scripts get autocomplete with no extra steps. To update, search again and download the new version over the old one.

## Wally

For a Rojo project, add packages to `wally.toml` and install from the command line.

1. Install the toolchain once with [Rokit](https://github.com/rojo-rbx/rokit): in your project folder run `rokit init`, then `rokit add UpliftGames/wally` and `rokit add rojo-rbx/rojo`.
2. Create `wally.toml` if you do not have one (`wally init`), and add dependencies:

```toml
[package]
name = "you/your-game"
version = "0.1.0"
registry = "https://github.com/UpliftGames/wally-index"
realm = "shared"

[dependencies]
Binder = "kashtheking/binder@0.6.3"
Packet = "kashtheking/packet@1.0.0"
t = "kashtheking/t@1.0.0"
```

3. Run `wally install`. Packages land in a `Packages/` folder next to `wally.toml`, with dependencies resolved (Binder brings in Trove, Signal and Predicates).
4. Map that folder in your `default.project.json` so Rojo syncs it to `ReplicatedStorage.Packages`:

```json
{
	"name": "your-game",
	"tree": {
		"$className": "DataModel",
		"ReplicatedStorage": {
			"Packages": { "$path": "Packages" }
		}
	}
}
```

5. For type information in your editor, generate a sourcemap (`rojo sourcemap default.project.json -o sourcemap.json`) and point luau-lsp at it, or run `wally-package-types` after installing.

Versions in the docs are the latest at the time of writing; `wally search kashtheking` or the [Wally site](https://wally.run/?q=kashtheking) always has the current list.

## Packager building blocks

[Building blocks](../building-blocks/index.md) are whole systems, sometimes with their package dependencies bundled, distributed as `.rbxm` files and installed with the [Packager plugin](../plugins/packager.md).

1. Download the block's `.rbxm` from its page.
2. In Studio, **Insert from File** in the Explorer.
3. Open Packager, select the inserted package, press **Unpackage**. Everything moves to the services it was packaged from.

Use this when you want a finished system rather than a library to build on, or when you are teaching someone who does not want to touch tooling yet.

## Which packages do what

The [Packages overview](../packages/index.md) groups everything by purpose. As a rule of thumb: [Binder](../packages/binder.md) for anything attached to instances, [Packet](../packages/packet.md) for networking, [t](../packages/t.md) for validation, [Hitbox](../packages/hitbox.md), [CameraController](../packages/camera-controller.md) and [GuiHandler](../packages/gui-handler.md) for the gameplay layer.

## Troubleshooting

- **`Packages.X is not a valid member`**: the package did not install where you are requiring from. Check whether you picked Shared or Server module, or whether Rojo is syncing the `Packages` folder.
- **Types are `any`**: in Studio Wally re-download the package (types are re-exported on download); in a Rojo project run `wally-package-types --sourcemap sourcemap.json Packages/`.
- **Two versions of Trove or Signal**: harmless. Wally keeps each package's exact dependency version under `Packages/_Index`.

Still stuck? Ask in the [Discord](https://discord.gg/6HYgCk22eD).

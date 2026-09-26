---
title: CameraController
sidebar_label: CameraController
sidebar_position: 4
description: "An object-oriented camera controller: one update function per camera mode, swap modes safely."
---

# CameraController

<div className="library-links">

[API reference](/api/CameraController) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/CameraController) [Wally page](https://wally.run/package/kashtheking/camera-controller)

</div>

<span className="library-card-meta">@1.5.4</span>

**An object-oriented camera controller: one update function per camera mode, swap modes safely.**

CameraController owns the client's `Camera` for as long as it is started. You give it an update function that runs every frame and an optional reset function that restores the camera when the controller stops. Only one controller is current at a time, so switching from a shoulder camera to a cutscene camera is a `Stop` and a `Start` with nothing leaking between them.

Runs on the **client** only.

## Use it when

- Your game has more than one camera behaviour (first person, over the shoulder, vehicle, cutscene).
- You want camera code that can be locked, unlocked and destroyed like any other object.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/camera-controller`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
CameraController = "kashtheking/camera-controller@1.5.4"
```

```lua
local CameraController = require(ReplicatedStorage.Packages.CameraController)
```

## Dependencies

Wally installs these automatically:

- [`sleitnick/trove@1.5.1`](https://wally.run/package/sleitnick/trove)

## Credits

Trove is by [sleitnick](https://github.com/Sleitnick) ([RbxUtil](https://sleitnick.github.io/RbxUtil/)).

## API

Every constructor, method, property and type is documented on the [CameraController API page](/api/CameraController), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/CameraController/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

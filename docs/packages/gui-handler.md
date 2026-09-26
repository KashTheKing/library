---
title: GuiHandler
sidebar_label: GuiHandler
sidebar_position: 8
description: "Show and hide ScreenGuis with configurable tweens, and manage them all from one place."
---

# GuiHandler

<div className="library-links">

[API reference](/api/GuiHandler) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/GuiHandler) [Wally page](https://wally.run/package/kashtheking/gui-handler)

</div>

<span className="library-card-meta">@1.0.1</span>

:::danger
Versions before 1.0.1 are broken. Install 1.0.1 or later only.
:::

**Show and hide ScreenGuis with configurable tweens, and manage them all from one place.**

GuiHandler pairs a `ScreenGui` with its main container and gives it `Show`, `Hide` and `Animate` methods that tween the container on and off screen. Each handler has an animation config (the properties to tween to when showing and hiding, and a TweenInfo for each), with a default that slides the container in from above, and static helpers let you show or hide every registered GUI at once or wait for one to be registered.

Runs on the **client** only.

## Use it when

- Every menu in your game should slide in and out the same way without hand-writing tweens.
- You need to hide all UI for a cutscene and bring it back afterwards.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/gui-handler`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
GuiHandler = "kashtheking/gui-handler@1.0.1"
```

```lua
local GuiHandler = require(ReplicatedStorage.Packages.GuiHandler)
```

## Dependencies

Wally installs these automatically:

- [`sleitnick/signal@2.0.3`](https://wally.run/package/sleitnick/signal)
- [`sleitnick/trove@1.5.1`](https://wally.run/package/sleitnick/trove)

## Credits

Trove and Signal are by [sleitnick](https://github.com/Sleitnick) ([RbxUtil](https://sleitnick.github.io/RbxUtil/)).

## API

Every constructor, method, property and type is documented on the [GuiHandler API page](/api/GuiHandler), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/GuiHandler/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

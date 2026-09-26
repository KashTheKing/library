---
title: SoundPool
sidebar_label: SoundPool (deprecated)
sidebar_position: 14
description: "A pool of positional Sound parts for rapid-fire SFX, such as hits in a fighting game."
---

# SoundPool

<div className="library-links">

[API reference](/api/SoundPool) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/SoundPool) [Wally page](https://wally.run/package/kashtheking/sound-pool)

</div>

<span className="library-card-meta library-card-meta--deprecated">@0.1.0 · deprecated</span>

:::caution Deprecated
No longer maintained. It works but has not kept up with Roblox's newer audio API.
:::

**A pool of positional Sound parts for rapid-fire SFX, such as hits in a fighting game.**

SoundPool keeps a minimum and maximum number of parts with a `Sound` each, hands one out for every `PlaySound`, and returns it to the pool when playback finishes. Each playback is an object you can pause, resume, stop or reconfigure. Built on frqstbite's object-pool.

## Use it when

- You play many short positional sounds per second and want to cap instance churn.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/sound-pool`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
SoundPool = "kashtheking/sound-pool@0.1.0"
```

```lua
local SoundPool = require(ReplicatedStorage.Packages.SoundPool)
```

## Dependencies

Wally installs these automatically:

- [`sleitnick/trove@1.8.0`](https://wally.run/package/sleitnick/trove)
- [`sleitnick/signal@2.0.3`](https://wally.run/package/sleitnick/signal)
- [`frqstbite/object-pool@1.0.2`](https://wally.run/package/frqstbite/object-pool)

## Credits

Trove and Signal are by [sleitnick](https://github.com/Sleitnick) ([RbxUtil](https://sleitnick.github.io/RbxUtil/)); object-pool is by [frqstbite](https://github.com/frqstbite).

## API

Every constructor, method, property and type is documented on the [SoundPool API page](/api/SoundPool), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/SoundPool/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

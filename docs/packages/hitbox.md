---
title: Hitbox
sidebar_label: Hitbox
sidebar_position: 9
description: "Object-oriented hitboxes on GetPartsInPart, with welding, timed scans and humanoid filtering."
---

# Hitbox

<div className="library-links">

[API reference](/api/Hitbox) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/Hitbox) [Wally page](https://wally.run/package/kashtheking/hitbox)

</div>

<span className="library-card-meta">@1.0.3</span>

**Object-oriented hitboxes on `GetPartsInPart`, with welding, timed scans and humanoid filtering.**

Hitbox creates an invisible part (or converts one of yours) and scans it with `Workspace:GetPartsInPart` on demand, on a timer, or on any signal. It can weld to a moving part, filter hits with a predicate, report parts or the humanoids they belong to, and cleans itself up with a Trove. It is built for melee, projectiles and area effects.

## Use it when

- You need a hitbox that follows a sword, a fist or a vehicle for a fixed duration.
- You want the humanoids inside a volume, deduplicated, every frame or every n seconds.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/hitbox`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
Hitbox = "kashtheking/hitbox@1.0.3"
```

```lua
local Hitbox = require(ReplicatedStorage.Packages.Hitbox)
```

## Dependencies

Wally installs these automatically:

- [`sleitnick/trove@1.5.1`](https://wally.run/package/sleitnick/trove)
- [`sleitnick/timer@1.1.2`](https://wally.run/package/sleitnick/timer)

## Credits

Trove and Timer are by [sleitnick](https://github.com/Sleitnick) ([RbxUtil](https://sleitnick.github.io/RbxUtil/)).

## API

Every constructor, method, property and type is documented on the [Hitbox API page](/api/Hitbox), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/Hitbox/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

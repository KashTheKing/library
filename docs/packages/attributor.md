---
title: Attributor
sidebar_label: Attributor
sidebar_position: 1
description: "Read and write an instance's attributes as if they were plain properties."
---

# Attributor

<div className="library-links">

[API reference](/api/Attributor) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/Attributor) [Wally page](https://wally.run/package/kashtheking/attributor)

</div>

<span className="library-card-meta">v1.0.0</span>

**Read and write an instance's attributes as if they were plain properties.**

Attributor wraps an instance in a small proxy object. Indexing the proxy reads the attribute of the same name, assigning to it calls `SetAttribute`, and `Destroy()` clears the proxy when you are done. It removes the `GetAttribute`/`SetAttribute` boilerplate from code that treats attributes as its data model.

## Use it when

- You store gameplay state in attributes (health, owner, level) and want `data.Health += 1` instead of `Get`/`Set` calls.
- You want a single object to hand around instead of an instance plus a bag of attribute names.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/attributor`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
Attributor = "kashtheking/attributor@1.0.0"
```

```lua
local Attributor = require(ReplicatedStorage.Packages.Attributor)
```

## Dependencies

None. The package is a single module with no dependencies.

## API

Every constructor, method, property and type is documented on the [Attributor API page](/api/Attributor), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/Attributor/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

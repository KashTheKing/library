---
title: ClassProperties
sidebar_label: ClassProperties
sidebar_position: 5
description: "Typed constructors for every Roblox class's properties, for type-checking pseudo-instances."
---

# ClassProperties

<div className="library-links">

[API reference](/api/ClassProperties) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/ClassProperties) [Wally page](https://wally.run/package/kashtheking/class-properties)

</div>

<span className="library-card-meta">v0.2.0</span>

**Typed constructors for every Roblox class's properties, for type-checking pseudo-instances.**

ClassProperties is a table keyed by Roblox class name where each entry describes that class's properties with Luau types. Use it to type-check plain tables that stand in for instances (deserialized saves, network payloads, editor state) before turning them into real instances.

## Use it when

- You serialize instances to tables and want strict typing when reading them back.
- You build tooling or plugins that manipulate instance-shaped data before instances exist.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/class-properties`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
ClassProperties = "kashtheking/class-properties@0.2.0"
```

```lua
local ClassProperties = require(ReplicatedStorage.Packages.ClassProperties)
```

## Dependencies

None. The package is a single module with no dependencies.

## API

Every constructor, method, property and type is documented on the [ClassProperties API page](/api/ClassProperties), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/ClassProperties/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

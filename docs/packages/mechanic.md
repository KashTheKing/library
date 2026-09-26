---
title: Mechanic
sidebar_label: Mechanic (deprecated)
sidebar_position: 11
description: "A component-style binder that applies logic to CollectionService-tagged instances."
---

# Mechanic

<div className="library-links">

[API reference](/api/Mechanic) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/Mechanic) [Wally page](https://wally.run/package/kashtheking/mechanic)

</div>

<span className="library-card-meta library-card-meta--deprecated">@4.0.3 · deprecated</span>

:::caution Deprecated
Superseded by [Binder](./binder.md), which does the same job with more filters and a cleaner API. Existing projects can keep using Mechanic; new ones should start with Binder.
:::

:::danger
Versions before 4.0.3 are broken. Install 4.0.3 only.
:::

**A component-style binder that applies logic to CollectionService-tagged instances.**

Mechanic watches a CollectionService tag and applies your logic to every matching instance, with filters for class name, ancestor and a custom predicate, per-instance data, shared data and a Trove per application. It is the older design that Binder grew out of.

## Use it when

- You maintain a project already built on Mechanic.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/mechanic`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
Mechanic = "kashtheking/mechanic@4.0.3"
```

```lua
local Mechanic = require(ReplicatedStorage.Packages.Mechanic)
```

## Dependencies

Wally installs these automatically:

- [`sleitnick/signal@2.0.3`](https://wally.run/package/sleitnick/signal)
- [`sleitnick/trove@1.5.1`](https://wally.run/package/sleitnick/trove)

## Credits

Trove and Signal are by [sleitnick](https://github.com/Sleitnick) ([RbxUtil](https://sleitnick.github.io/RbxUtil/)).

## API

Every constructor, method, property and type is documented on the [Mechanic API page](/api/Mechanic), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/Mechanic/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

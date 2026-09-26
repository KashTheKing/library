---
title: Binder
sidebar_label: Binder
sidebar_position: 3
description: "Bind a class to instances by tag, class name, ancestor or predicate, and clean up when they leave."
---

# Binder

<div className="library-links">

[API reference](/api/Binder) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/Binder) [Wally page](https://wally.run/package/kashtheking/binder)

</div>

<span className="library-card-meta">@0.6.3</span>

**Bind a class to instances by tag, class name, ancestor or predicate, and clean up when they leave.**

Binder watches the game for instances that match a filter and constructs your class for each one, handing it a [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) that is cleaned when the instance no longer matches. Filters combine CollectionService tags, class whitelists, ancestor whitelists and custom predicates, and a priority lets several binders construct in a defined order on the same frame. It is the successor to [Mechanic](./mechanic.md).

## Use it when

- You build gameplay as components attached to tagged parts or models (doors, buttons, pickups, NPCs).
- You want deterministic setup order between systems and guaranteed cleanup with no leaked connections.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/binder`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
Binder = "kashtheking/binder@0.6.3"
```

```lua
local Binder = require(ReplicatedStorage.Packages.Binder)
```

## Dependencies

Wally installs these automatically:

- [`sleitnick/trove@1.8.0`](https://wally.run/package/sleitnick/trove)
- [`sleitnick/signal@2.0.3`](https://wally.run/package/sleitnick/signal)
- [`kashtheking/predicates@0.2.3`](https://wally.run/package/kashtheking/predicates)

## Credits

Trove and Signal are by [sleitnick](https://github.com/Sleitnick) ([RbxUtil](https://sleitnick.github.io/RbxUtil/)). Predicates is my own package.

## API

Every constructor, method, property and type is documented on the [Binder API page](/api/Binder), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/Binder/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

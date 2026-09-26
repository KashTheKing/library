---
title: Predicates
sidebar_label: Predicates
sidebar_position: 14
description: "Composable predicate functions for instances: attributes, children, characters, players, and combinations."
---

# Predicates

<div className="library-links">

[API reference](/api/Predicates) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/Predicates) [Wally page](https://wally.run/package/kashtheking/predicates)

</div>

<span className="library-card-meta">@0.2.3</span>

**Composable predicate functions for instances: attributes, children, characters, players, and combinations.**

Predicates is a library of factories that build `(instance) -> (boolean, ...)` functions: require an attribute of a given type, a child or descendant of a class, a PrimaryPart, a Humanoid, a character or a Player, gate on server/client, and `Combine` several into one. Passing predicates hand their findings back as extra return values, which is how [Binder](./binder.md) feeds them into your constructor. Type checks come from [t](./t.md).

## Use it when

- You need a readable, reusable filter instead of an inline `if part:IsA(...) and part:GetAttribute(...)`.
- You are writing a Binder and want its filter as a named predicate.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/predicates`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
Predicates = "kashtheking/predicates@0.2.3"
```

```lua
local Predicates = require(ReplicatedStorage.Packages.Predicates)
```

## Dependencies

Wally installs these automatically:

- [`kashtheking/t@1.0.0`](https://wally.run/package/kashtheking/t)

## Credits

Type validation uses [t](./t.md), originally by [Osyris](https://github.com/osyrisrblx).

## API

Every constructor, method, property and type is documented on the [Predicates API page](/api/Predicates), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/Predicates/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

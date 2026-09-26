---
title: t
sidebar_label: t
sidebar_position: 16
description: "A runtime type checker: build a check once, validate any value with a clear error message."
---

# t

<div className="library-links">

[API reference](/api/t) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/t) [Wally page](https://wally.run/package/kashtheking/t)

</div>

<span className="library-card-meta">v1.0.0</span>

**A runtime type checker: build a check once, validate any value with a clear error message.**

t is my published build of the classic `t` runtime type checker for Roblox. Every function returns a check `(value) -> (boolean, string?)`, and checks compose: `t.interface`, `t.tuple`, `t.union`, `t.optional`, `t.instanceOf` and dozens more. Use it to validate remote arguments, config tables and DataStore payloads, and to make [Predicates](./predicates.md) type-aware.

## Use it when

- You need to validate what a client sent before trusting it.
- You want readable, composable schema checks for configuration and saved data.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/t`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
t = "kashtheking/t@1.0.0"
```

```lua
local t = require(ReplicatedStorage.Packages.t)
```

## Dependencies

None. The package is a single module with no dependencies.

## API

Every constructor, method, property and type is documented on the [t API page](/api/t), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/t/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

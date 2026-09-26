---
title: StateManager
sidebar_label: StateManager (deprecated)
sidebar_position: 16
description: "A named-state machine with enter/exit callbacks and a Trove per state."
---

# StateManager

<div className="library-links">

[API reference](/api/StateManager) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/StateManager) [Wally page](https://wally.run/package/kashtheking/state-manager)

</div>

<span className="library-card-meta library-card-meta--deprecated">@2.1.1 · deprecated</span>

:::caution Deprecated
No longer maintained. New projects should model state with Binder-bound objects or their own state machine.
:::

:::danger
Versions before 2.1.1 are broken. Install 2.1.1 only.
:::

**A named-state machine with enter/exit callbacks and a Trove per state.**

StateManager holds a set of named `State` objects and moves between them with `ChangeState`. Each state's `OnEnter` callback receives a Trove that is cleaned on exit, so connections made inside a state never outlive it. States can be loaded from a folder of ModuleScripts.

## Use it when

- You maintain a project already built on StateManager.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/state-manager`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
StateManager = "kashtheking/state-manager@2.1.1"
```

```lua
local StateManager = require(ReplicatedStorage.Packages.StateManager)
```

## Dependencies

Wally installs these automatically:

- [`sleitnick/signal@2.0.3`](https://wally.run/package/sleitnick/signal)
- [`sleitnick/trove@1.5.1`](https://wally.run/package/sleitnick/trove)

## Credits

Trove and Signal are by [sleitnick](https://github.com/Sleitnick) ([RbxUtil](https://sleitnick.github.io/RbxUtil/)).

## API

Every constructor, method, property and type is documented on the [StateManager API page](/api/StateManager), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/StateManager/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

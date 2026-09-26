---
title: ClientSettings
sidebar_label: ClientSettings (deprecated)
sidebar_position: 6
description: "A bare-bones store for local (client) settings that fires a Signal when a setting changes."
---

# ClientSettings

<div className="library-links">

[API reference](/api/ClientSettings) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/ClientSettings) [Wally page](https://wally.run/package/kashtheking/local-settings)

</div>

<span className="library-card-meta library-card-meta--deprecated">@0.1.0 · deprecated</span>

:::caution Deprecated
No longer maintained. It still works, but it is a bare-bones module and new projects should keep settings in their own state layer.
:::

**A bare-bones store for local (client) settings that fires a Signal when a setting changes.**

ClientSettings is a table you assign settings into (`Settings.MusicVolume = 0.5`) plus a `SettingChanged` [Signal](https://sleitnick.github.io/RbxUtil/api/Signal/) that fires with the key and new value on every assignment, so UI and gameplay can react without polling. The Wally package is named `local-settings`.

Runs on the **client** only.

## Use it when

- You need a tiny settings table with a change event and nothing else.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/local-settings`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
ClientSettings = "kashtheking/local-settings@0.1.0"
```

```lua
local ClientSettings = require(ReplicatedStorage.Packages.ClientSettings)
```

## Dependencies

Wally installs these automatically:

- [`sleitnick/signal@2.0.3`](https://wally.run/package/sleitnick/signal)

## Credits

Signal is by [sleitnick](https://github.com/Sleitnick) ([RbxUtil](https://sleitnick.github.io/RbxUtil/)).

## API

Every constructor, method, property and type is documented on the [ClientSettings API page](/api/ClientSettings), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/ClientSettings/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

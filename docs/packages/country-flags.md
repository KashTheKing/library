---
title: CountryFlags
sidebar_label: CountryFlags
sidebar_position: 7
description: "Turn a country, region or language code into its flag emoji, and look up a player's region."
---

# CountryFlags

<div className="library-links">

[API reference](/api/CountryFlags) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/CountryFlags) [Wally page](https://wally.run/package/kashtheking/Country-Flags)

</div>

<span className="library-card-meta">@0.1.0</span>

**Turn a country, region or language code into its flag emoji, and look up a player's region.**

CountryFlags maps ISO country codes to flag emoji, maps common language codes to a representative country, splits `en-us` style region strings, and wraps `LocalizationService` so the server can look up which country a player is connecting from. Handy for leaderboards, chat tags and region-aware UI.

## Use it when

- You show where players are from in a leaderboard or chat.
- You need a flag for a language or locale string, not just a country.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/Country-Flags`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
CountryFlags = "kashtheking/Country-Flags@0.1.0"
```

```lua
local CountryFlags = require(ReplicatedStorage.Packages.CountryFlags)
```

## Dependencies

None. The package is a single module with no dependencies.

## Credits

Written by KashTheKing. No third-party code.

## API

Every constructor, method, property and type is documented on the [CountryFlags API page](/api/CountryFlags), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/CountryFlags/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

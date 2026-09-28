---
title: Flashback
sidebar_label: Flashback
sidebar_position: 18
description: "The Flashback replay module: record gameplay on the server and play it back on the client or in Studio."
---

# Flashback

<div className="library-links">

[API reference](https://kashtheking.com/flashback/api/Recorder/) [Full documentation](https://kashtheking.com/flashback/) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/Flashback)

</div>

<span className="library-card-meta">v1.0.0</span>

**The Flashback module: record gameplay on the server, play it back anywhere.**

Flashback captures tracked instances into a compact binary replay and drives lightweight proxies on the client or inside Roblox Studio, with play, pause, seek and variable speed. Use it for kill cams, match replays, anti-cheat review and bug reproduction.

This is the open-source core of the [Flashback plugin](../plugins/flashback.md). The plugin adds the installer, one-click recording, the replay browser and Moon Animator export.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/flashback`.
3. Press download and choose **Shared module**.

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
Flashback = "kashtheking/flashback@1.0.0"
```

## Example

```lua
local Flashback = require(ReplicatedStorage.Packages.Flashback)

-- server
local rec = Flashback.Recorder.new({ tickRate = 15 })
rec:start()
Flashback.Store.save("match_1", rec:stop())

-- client
local player = Flashback.Player.new(Flashback.Store.load("match_1"))
player:play()
```

## Dependencies

None.

## Help

Guides and the API reference live on the [Flashback site](https://kashtheking.com/flashback/). Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues).

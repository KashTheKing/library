---
title: Flashback
sidebar_position: 6
description: Record Roblox gameplay on the server and play it back anywhere, with scrubbing, pause and slow motion.
---

# Flashback

<div className="library-links">

[Full documentation](https://kashtheking.com/flashback/) [Get it on the Creator Store](https://create.roblox.com/store/asset/81981489933039/Flashback-Record-and-Replay-Gameplay) [Flashback package](../packages/flashback.md) [This page's source](https://github.com/KashTheKing/library/tree/main/plugins/flashback)

</div>

<span className="library-card-meta">paid plugin · MIT module</span>

![Flashback icon](/img/flashback-icon.png)

**Record gameplay on the server. Play it back anywhere, with scrubbing, pause and slow motion.**

Flashback captures your game into a compact binary replay and plays it back on lightweight proxies, on the client or right inside Studio. Use it for kill cams, match replays, anti-cheat review, trailers and bug reproduction. One ModuleScript, zero dependencies.

- **Server-side recording.** Player characters are tracked automatically; tag anything else and it's captured too, animations included.
- **Full playback control.** Play, pause, seek to any second and change speed, or drive the clock yourself for cinematic cuts.
- **Studio plugin.** Install the module, record, tag instances and browse saved replays from a widget that follows the Studio theme. No code needed.
- **Compact format.** Delta ticks with periodic keyframes keep replays small, with a live size estimate while recording.
- **Your choice of storage.** DataStore with 3 MB chunking, any HTTP backend, or the plugin's local settings file.
- **Moon Animator export.** Turn a replay into a Moon Animator 2 save and polish it into a cutscene.
- **Extensible.** Record any bool, number, string, Color3, Vector3 or Enum property per class, fire timeline events (kills, goals, rounds) and add custom binary channels.

The plugin is paid and closed-source. The `Flashback` module it installs is MIT licensed, open source in this library at [packages/src/Flashback](https://github.com/KashTheKing/library/tree/main/packages/src/Flashback), and installable on its own as the Wally package [`kashtheking/flashback`](../packages/flashback.md).

## Where the docs are

Flashback has its own site with the plugin guide, recording and playback guides, storage options, Moon Animator export and the replay format: **[kashtheking.com/flashback](https://kashtheking.com/flashback/)**. This page is only a pointer so the plugin is listed with the rest of the library.

## Help

[Discord](https://discord.gg/6HYgCk22eD) · [Help & contact](../support.md)

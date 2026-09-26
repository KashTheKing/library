---
title: Packet
sidebar_label: Packet
sidebar_position: 12
description: "Buffer-based networking: declare a packet's types once, then fire and respond with typed values."
---

# Packet

<div className="library-links">

[API reference](/api/Packet) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/Packet) [Wally page](https://wally.run/package/kashtheking/packet)

</div>

<span className="library-card-meta">v1.0.0</span>

**Buffer-based networking: declare a packet's types once, then fire and respond with typed values.**

Packet replaces ad-hoc RemoteEvents with named packets whose parameter types you declare once. Values are serialized into a `buffer` (with a side list for instances), so payloads are compact and every send is checked against the declared types. Packets support fire-and-forget on both sides, server-to-one-client, and request/response with a timeout.

## Use it when

- You send frequent small updates and want to cut bandwidth and avoid untyped remotes.
- You want one file that declares every network message in your game, shared by server and client.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/packet`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
Packet = "kashtheking/packet@1.0.0"
```

```lua
local Packet = require(ReplicatedStorage.Packages.Packet)
```

## Dependencies

None. The package is a single module with no dependencies.

## API

Every constructor, method, property and type is documented on the [Packet API page](/api/Packet), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/Packet/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

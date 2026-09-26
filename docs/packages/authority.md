---
title: Authority
sidebar_label: Authority
sidebar_position: 2
description: "A server-authoritative state holder that replicates its values through attributes."
---

# Authority

<div className="library-links">

[API reference](/api/Authority) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages/src/Authority) [Wally page](https://wally.run/package/kashtheking/authority)

</div>

<span className="library-card-meta">v0.2.3</span>

**A server-authoritative state holder that replicates its values through attributes.**

Authority gives you a typed table of values that lives on an instance's attributes. The server owns the values; clients read the same object and see changes as the attributes replicate. It is the smallest possible way to share state per instance without writing remotes.

## Use it when

- You need per-instance state (a door's locked flag, a tycoon's owner) visible to every client without RemoteEvents.
- You want the server to be the only writer, enforced rather than agreed on.

## Install

### Studio Wally

Using the [Studio Wally plugin](../plugins/studio-wally.md):

1. Open the widget.
2. Search `kashtheking/authority`.
3. Press download and choose **Shared module** (recommended for almost every package).

### Wally

Add this to the `[dependencies]` section of your `wally.toml`, then run `wally install`:

```toml
Authority = "kashtheking/authority@0.2.3"
```

```lua
local Authority = require(ReplicatedStorage.Packages.Authority)
```

## Dependencies

None. The package is a single module with no dependencies.

## API

Every constructor, method, property and type is documented on the [Authority API page](/api/Authority), generated from the doc comments in [`init.luau`](https://github.com/KashTheKing/library/tree/main/packages/src/Authority/init.luau). Each entry links to its line in the source.

## Help

Questions and bug reports: the [Discord](https://discord.gg/6HYgCk22eD) or a [GitHub issue](https://github.com/KashTheKing/library/issues). See [Help & contact](../support.md) for everything else.

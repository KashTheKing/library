---
title: Studio Wally
sidebar_position: 2
description: Search and download Wally packages, with package types, without leaving Roblox Studio.
---

# Studio Wally

<div className="library-links">

[Get it on the Creator Store](https://create.roblox.com/store/asset/133519889832441/Studio-Wally-With-package-types) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/plugins/studio-wally) [Packages to install](../packages/index.md)

</div>

<img className="library-icon" width="128" height="128" alt="Wally logo" src="https://github.com/user-attachments/assets/38ca3b09-ca8d-4feb-9188-a897d9ddc77c" />

**Search and download Wally packages without ever leaving Roblox Studio.**

I made this fork to keep fewkz's deprecated Studio Wally plugin alive and to add package types. It re-exports the types from installed packages, so `require` gives you full autocomplete and strict type checking, and it fixes a handful of general bugs. If you work in Studio without Rojo, this is the way to install every package in this library.

## How to use

1. Open the widget from the **Plugins** toolbar.
2. Search a Wally package by scope and name, for example `kashtheking/binder`.
3. Press the download button and choose a download option. **Shared module** is recommended for almost all packages: it puts the module (and its dependencies) in `ReplicatedStorage.Packages`, reachable from both server and client.

Every [package page](../packages/index.md) lists the exact string to search.

## Download options

| Option | Where it goes | Use for |
| --- | --- | --- |
| **Shared module** | `ReplicatedStorage.Packages` | Almost everything. Server and client can both require it. |
| Server module | `ServerScriptService` / `ServerStorage` | Packages that must never replicate to clients. |
| Dev module | Studio only | Tooling used while editing. |

Dependencies are installed alongside the package, so installing `kashtheking/binder` also brings in Trove, Signal and Predicates.

## Requiring what you installed

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Binder = require(ReplicatedStorage.Packages.Binder)
```

Because types are re-exported, `Binder.new(...)` is typed in strict mode with no extra work.

## Help

[Discord](https://discord.gg/6HYgCk22eD) · [GitHub issues](https://github.com/KashTheKing/library/issues) · [Help & contact](../support.md)

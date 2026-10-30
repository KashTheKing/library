---
title: Init
sidebar_label: Init
sidebar_position: 10
description: "My module loader: point it at folders and it loads, initializes and starts every module in order."
---

# Init

<div className="library-links">

[Full docs](https://kashtheking.com/init/) [Source on GitHub](https://github.com/KashTheKing/init) [Init Framework plugin](../plugins/init-framework.md)

</div>

<span className="library-card-meta">kashtheking/init@1.0.0</span>

**A module loader for Roblox games.** Nearly all of my games boot with it. Put your modules in folders; Init requires them in the order you list, calls every module's `Init`, then every module's `Start`, and connects `OnPlayerAdded`, `Step`, `OnCharacterAdded` and the rest for you.

## Install

- **No code:** the [Init Framework plugin](../plugins/init-framework.md), press **Setup**.
- **With AI:** paste the prompt from [Install with AI](https://kashtheking.com/init/docs/install/with-ai/).
- **Wally:** `Init = "kashtheking/init@1.0.0"`, then copy the boot scripts from the [example](https://github.com/KashTheKing/init/tree/main/example).

```lua
local Init = require(ReplicatedStorage.Packages.Init)

Init.start({
	{ Folders = { ReplicatedStorage.Network } },
	{ Folders = { ReplicatedStorage.Services, ServerScriptService.Services }, Predicate = Init.matchesName("Service$") },
})
```

Everything else (lifecycle, entries, settings, templates, the AI skill, troubleshooting) is at **[kashtheking.com/init](https://kashtheking.com/init/)**.

## Help

[Discord](https://discord.gg/6HYgCk22eD) · [GitHub issues](https://github.com/KashTheKing/init/issues) · [Help & contact](../support.md)

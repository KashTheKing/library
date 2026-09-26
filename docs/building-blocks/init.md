---
title: Init
sidebar_position: 1
description: A trusted module loader that requires and initializes your modules in a safe, ordered way.
---

# Init

<div className="library-links">

[Source on GitHub](https://github.com/KashTheKing/library/tree/main/building-blocks/init) [Init Framework plugin](../plugins/init-framework.md) [Init package (WIP)](../packages/init.md)

</div>

**A trusted module loader that requires and initializes your modules in a safe, ordered way.**

Init is my personal module loader and nearly all of my games boot with it. Instead of a tangle of scripts requiring each other at startup, you put your modules in folders, and Init requires them in a defined order, runs their initialization, and reports errors cleanly. The [Init Framework plugin](../plugins/init-framework.md) sets up a whole place around it in one click.

:::info Rework in progress
The Init package is being reworked. This building block is the current version. When the rework lands it will be published on Wally with an API reference here.
:::

## Install

1. Download the `.rbxm` from the [`building-blocks/init` folder](https://github.com/KashTheKing/library/tree/main/building-blocks/init) on GitHub.
2. In Roblox Studio, insert the file and open the [Packager plugin](../plugins/packager.md).
3. Click the `.rbxm` package and press **Unpackage** to drop it into your experience.

Or install the [Init Framework plugin](../plugins/init-framework.md) and let it set up the loader and folder structure for you.

## Help

[Discord](https://discord.gg/6HYgCk22eD) · [GitHub issues](https://github.com/KashTheKing/library/issues) · [Help & contact](../support.md)

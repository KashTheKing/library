---
title: Init
sidebar_position: 1
description: A trusted module loader that requires and initializes your modules in a safe, ordered way.
---

# Init

<div className="library-links">

[Full docs](https://kashtheking.com/init/) [Init package](../packages/init.md) [Init Framework plugin](../plugins/init-framework.md)

</div>

**A trusted module loader that requires and initializes your modules in a safe, ordered way.**

Init is my personal module loader and nearly all of my games boot with it. Instead of a tangle of scripts requiring each other at startup, you put your modules in folders, and Init requires them in a defined order, runs their initialization, and reports errors cleanly. The [Init Framework plugin](../plugins/init-framework.md) sets up a whole place around it in one click.

:::info Init is now a Wally package
Init 1.0 is on Wally as `kashtheking/init`, with its own docs at **[kashtheking.com/init](https://kashtheking.com/init/)**. Install it with the [Init Framework plugin](../plugins/init-framework.md), with Wally, or by dragging `Init.rbxm` from the [latest release](https://github.com/KashTheKing/init/releases/latest) into `ReplicatedStorage.Packages`. Coming from this building block? See [Migrating](https://kashtheking.com/init/docs/migrating/).
:::

## Help

[Discord](https://discord.gg/6HYgCk22eD) · [GitHub issues](https://github.com/KashTheKing/library/issues) · [Help & contact](../support.md)

---
title: Damage Part example
sidebar_position: 2
description: A simple damage part built on Binder, packaged with its dependency for the Packager plugin.
---

# Damage Part example

<div className="library-links">

[Download the .rbxm](https://github.com/KashTheKing/library/raw/main/building-blocks/packager-blocks/damage-part-example/damage-part-example.rbxm) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/building-blocks/packager-blocks/damage-part-example) [Binder package](../packages/binder.md)

</div>

**A simple damage part that uses [Binder](../packages/binder.md).** Touch it and you take damage. It exists mostly as an example of a [Packager](../plugins/packager.md) block that carries a dependency: the package contains the damage module *and* the Binder module it needs, so unpacking it into an empty place just works.

## Install

:::note
This building block uses [Packager](../plugins/packager.md) for installation.
:::

1. [Download the `.rbxm`](https://github.com/KashTheKing/library/raw/main/building-blocks/packager-blocks/damage-part-example/damage-part-example.rbxm).
2. Insert it into Roblox Studio (**Insert from File** in the Explorer).
3. Open Packager, select the package, and press **Unpackage**.

## Notes

- The module can be placed anywhere, just make sure to require it. Packager puts it where it was packaged from, but you are free to move it.
- Read the module after unpacking: it is a short, complete example of a Binder class with a constructor that receives an instance and a Trove, which is the pattern every Binder-based system in my games follows.

## Help

[Discord](https://discord.gg/6HYgCk22eD) · [GitHub issues](https://github.com/KashTheKing/library/issues) · [Help & contact](../support.md)

---
title: Building Blocks
sidebar_label: Overview
sidebar_position: 0
slug: /building-blocks
description: Fully built Roblox systems and assets as .rbxm files, free, installed with the Packager plugin.
---

# Building Blocks

<div className="library-links">

[Source on GitHub](https://github.com/KashTheKing/library/tree/main/building-blocks) [Packager plugin](../plugins/packager.md)

</div>

**Fully built systems and assets, for free.** Prebuilt models and scripts as `.rbxm` files. Download one, drop it into your experience with the [Packager plugin](../plugins/packager.md), and every piece lands where it belongs.

<div className="library-cards">
  <a className="library-card" href="./init/">
    <span className="library-card-meta">module loader</span>
    <h3>Init</h3>
    <p>A trusted module loader that requires and initializes your modules in a safe, ordered way.</p>
    <span className="library-card-cta">Install →</span>
  </a>
  <a className="library-card" href="./damage-part-example/">
    <span className="library-card-meta">example</span>
    <h3>Damage Part example</h3>
    <p>A simple damage part built on Binder, packaged with its dependency. Shows how a Packager block with dependencies installs.</p>
    <span className="library-card-cta">Install →</span>
  </a>
</div>

## Installing a building block

1. Install the [Packager plugin](../plugins/packager.md) if you have not already.
2. Download the block's `.rbxm` from its page (each links to the file on GitHub; use **Download raw file**).
3. In Studio, right-click in the Explorer and **Insert from File**, choosing the `.rbxm`. A single Packager package instance appears.
4. Open the Packager widget, click the package, and press **Unpackage**. Its scripts and instances move to the services they were packaged from.

Blocks are MIT licensed like the packages. Blocks that depend on a package (for example, the Damage Part on [Binder](../packages/binder.md)) include that dependency in the package, so you do not need to install it separately.

## Help

[Discord](https://discord.gg/6HYgCk22eD) · [GitHub issues](https://github.com/KashTheKing/library/issues) · [Help & contact](../support.md)

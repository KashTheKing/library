---
sidebar_position: 1
title: Getting started
slug: /intro
---

# Getting started

KashTheKing's Library is everything I reuse between my Roblox projects, published so you can grab it too: **packages** you install with Wally, **Studio plugins** from the Creator Store, ready-made **building blocks** you drop into a place, and **guides** that explain how I put games together. The whole thing lives in one repository, [github.com/KashTheKing/library](https://github.com/KashTheKing/library), and every page on this site links back to its source.

## Pick a section

<div className="library-cards">
  <a className="library-card" href="../packages/">
    <h3>Packages</h3>
    <p>Fifteen Luau modules for instance lifecycles, networking, hitboxes, cameras, GUIs, type checking and more. Install with Wally or the Studio Wally plugin.</p>
    <span className="library-card-cta">Browse packages →</span>
  </a>
  <a className="library-card" href="../plugins/">
    <h3>Plugins</h3>
    <p>Studio plugins I made or forked: Packager, Studio Wally, Bounding Box, Init Framework, Infinite Ocean, Flashback and the upcoming Viewmodel Editor.</p>
    <span className="library-card-cta">Browse plugins →</span>
  </a>
  <a className="library-card" href="../building-blocks/">
    <h3>Building Blocks</h3>
    <p>Fully built systems as <code>.rbxm</code> files. Download one, unpack it with Packager, and it is in your experience.</p>
    <span className="library-card-cta">Browse blocks →</span>
  </a>
  <a className="library-card" href="../guides/">
    <h3>Guides</h3>
    <p>Installing packages, using building blocks, contributing to the library, and full game walkthroughs as they are written.</p>
    <span className="library-card-cta">Read the guides →</span>
  </a>
</div>

## Three ways to install things

| You want | Use | How |
| --- | --- | --- |
| A package, from Studio, no tooling | [Studio Wally plugin](./plugins/studio-wally.md) | Open the widget, search `kashtheking/<name>`, download as a **Shared module**. |
| A package, in a Rojo project | [Wally](https://wally.run) | Add `Name = "kashtheking/<name>@<version>"` under `[dependencies]` in `wally.toml`, run `wally install`. |
| A whole system with its dependencies | [Packager plugin](./plugins/packager.md) | Download the block's `.rbxm`, insert it into Studio, press **Unpackage**. |

Every package page shows both install commands for its current version, and the [Installing packages guide](./guides/installing-packages.md) walks through each path in detail.

## Reading the API reference

The **API** tab at the top documents every package class from the doc comments in its source: constructors, methods, properties, types and which side (server or client) they run on. Each entry has a link to the exact line in the repository, so when the docs are not enough the code is one click away.

## Something missing or broken?

Every page has an **Edit this page** link at the bottom that opens its Markdown source on GitHub, and the navbar's **GitHub** link opens the repository itself. For questions and bug reports, join the [Discord](https://discord.gg/6HYgCk22eD) or see the [Support page](./support.md).

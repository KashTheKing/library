---
title: Packager
sidebar_position: 1
description: Easily package and unpack whole systems into your experiences.
---

# Packager

<div className="library-links">

[Get it on the Creator Store](https://create.roblox.com/store/asset/85885451493408/Packager) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/plugins/packager) [Example package](../building-blocks/damage-part-example.md)

</div>

<img className="library-icon" width="128" height="128" alt="Packager icon" src="https://github.com/user-attachments/assets/aef0c9ed-1941-42c2-812e-7f8d414ba278" />

**Easily package and unpack systems into your experiences.**

I made this plugin because I reuse complex systems all the time, and zipping one up into a folder, writing instructions for where every piece goes, then unzipping it in another experience is a pain. Packager turns that into a simple explorer widget: group your systems the way you want, then package or unpackage them with one click. It is also how every [building block](../building-blocks/index.md) in this library installs.

Forked from [@likeablesea7](https://www.roblox.com/users/likeablesea7/profile)'s Custom Explorer v1.5.1.

## How to use

### Organize

1. Open the widget from the **Plugins** toolbar.
2. Select the scripts and instances that make up a system.
3. Press **Add to group** to put them in a group. Groups are just an organizational view; nothing moves in the Explorer.

### Package

1. Open the widget.
2. Click a group to select it.
3. Press the export button. Packager writes a certified Packager package: one instance that records where each part of the system belongs.

### Unpackage

1. Open the widget.
2. Click a Packager package in your place (for example, a `.rbxm` you just inserted).
3. Press **Unpackage**. Every piece is moved to the service and path it was packaged from.

:::caution
Packager does not scan for malicious instances or code. Only unpack packages from sources you trust. I am not responsible for the systems you unpack into your experience.
:::

## Example

The [Damage Part example](../building-blocks/damage-part-example.md) is a small module with a dependency ([Binder](../packages/binder.md)) packaged this way. Download the `.rbxm`, insert it, and unpack it to see how a package with dependencies lands.

## Help

[Discord](https://discord.gg/6HYgCk22eD) · [GitHub issues](https://github.com/KashTheKing/library/issues) · [Help & contact](../support.md)

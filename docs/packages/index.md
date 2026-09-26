---
title: Packages
sidebar_label: Overview
sidebar_position: 0
slug: /packages
description: "All of KashTheKing's maintained and distributed Roblox packages, installable with Wally or the Studio Wally plugin."
---

# Packages

<div className="library-links">

[API reference](/api/) [Source on GitHub](https://github.com/KashTheKing/library/tree/main/packages) [kashtheking on Wally](https://wally.run/?q=kashtheking)

</div>

All of my maintained and distributed packages: reusable Luau modules, installable with [Wally](https://wally.run) or the [Studio Wally plugin](../plugins/studio-wally.md). Each package has its own page with install instructions and a link to its generated [API reference](/api/). Packages are MIT licensed.

Most packages depend on [sleitnick's Trove and Signal](https://sleitnick.github.io/RbxUtil/); Wally installs those for you. If you install by hand, grab them too.

## Instances & lifecycle

<div className="library-cards">
  <a className="library-card" href="./attributor/">
    <span className="library-card-meta">v1.0.0</span>
    <h3>Attributor</h3>
    <p>Read and write an instance's attributes as if they were plain properties.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
  <a className="library-card" href="./authority/">
    <span className="library-card-meta">v0.2.3</span>
    <h3>Authority</h3>
    <p>A server-authoritative state holder that replicates its values through attributes.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
  <a className="library-card" href="./binder/">
    <span className="library-card-meta">v0.6.3</span>
    <h3>Binder</h3>
    <p>Bind a class to instances by tag, class name, ancestor or predicate, and clean up when they leave.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
  <a className="library-card" href="./predicates/">
    <span className="library-card-meta">v0.2.3</span>
    <h3>Predicates</h3>
    <p>Composable predicate functions for instances: attributes, children, characters, players, and combinations.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
</div>

## Networking & state

<div className="library-cards">
  <a className="library-card" href="./packet/">
    <span className="library-card-meta">v1.0.0</span>
    <h3>Packet</h3>
    <p>Buffer-based networking: declare a packet's types once, then fire and respond with typed values.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
</div>

## Gameplay

<div className="library-cards">
  <a className="library-card" href="./camera-controller/">
    <span className="library-card-meta">v1.5.4</span>
    <h3>CameraController</h3>
    <p>An object-oriented camera controller: one update function per camera mode, swap modes safely.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
  <a className="library-card" href="./gui-handler/">
    <span className="library-card-meta">v1.0.1</span>
    <h3>GuiHandler</h3>
    <p>Show and hide ScreenGuis with configurable tweens, and manage them all from one place.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
  <a className="library-card" href="./hitbox/">
    <span className="library-card-meta">v1.0.3</span>
    <h3>Hitbox</h3>
    <p>Object-oriented hitboxes on <code>GetPartsInPart</code>, with welding, timed scans and humanoid filtering.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
</div>

## Utilities

<div className="library-cards">
  <a className="library-card" href="./class-properties/">
    <span className="library-card-meta">v0.2.0</span>
    <h3>ClassProperties</h3>
    <p>Typed constructors for every Roblox class's properties, for type-checking pseudo-instances.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
  <a className="library-card" href="./country-flags/">
    <span className="library-card-meta">v0.1.0</span>
    <h3>CountryFlags</h3>
    <p>Turn a country, region or language code into its flag emoji, and look up a player's region.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
  <a className="library-card" href="./t/">
    <span className="library-card-meta">v1.0.0</span>
    <h3>t</h3>
    <p>A runtime type checker: build a check once, validate any value with a clear error message.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
</div>

## Deprecated

<div className="library-cards">
  <a className="library-card" href="./client-settings/">
    <span className="library-card-meta library-card-meta--deprecated">v0.1.0 · deprecated</span>
    <h3>ClientSettings</h3>
    <p>A bare-bones store for local (client) settings that fires a Signal when a setting changes.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
  <a className="library-card" href="./mechanic/">
    <span className="library-card-meta library-card-meta--deprecated">v4.0.3 · deprecated</span>
    <h3>Mechanic</h3>
    <p>A component-style binder that applies logic to CollectionService-tagged instances.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
  <a className="library-card" href="./sound-pool/">
    <span className="library-card-meta library-card-meta--deprecated">v0.1.0 · deprecated</span>
    <h3>SoundPool</h3>
    <p>A pool of positional Sound parts for rapid-fire SFX, such as hits in a fighting game.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
  <a className="library-card" href="./state-manager/">
    <span className="library-card-meta library-card-meta--deprecated">v2.1.1 · deprecated</span>
    <h3>StateManager</h3>
    <p>A named-state machine with enter/exit callbacks and a Trove per state.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
</div>

## Building block

<div className="library-cards">
  <a className="library-card" href="./init/">
    <span className="library-card-meta">work in progress</span>
    <h3>Init</h3>
    <p>My trusted module loader. Being reworked; the current version ships as a building block.</p>
    <span className="library-card-cta">Docs →</span>
  </a>
</div>

## All versions

<div className="library-versions">

| Package | Wally | Latest | Description |
| --- | --- | --- | --- |
| [Attributor](./attributor.md) | `kashtheking/attributor` | `@1.0.0` | Read and write an instance's attributes as if they were plain properties. |
| [Authority](./authority.md) | `kashtheking/authority` | `@0.2.3` | A server-authoritative state holder that replicates its values through attributes. |
| [Binder](./binder.md) | `kashtheking/binder` | `@0.6.3` | Bind a class to instances by tag, class name, ancestor or predicate, and clean up when they leave. |
| [CameraController](./camera-controller.md) | `kashtheking/camera-controller` | `@1.5.4` | An object-oriented camera controller: one update function per camera mode, swap modes safely. |
| [ClassProperties](./class-properties.md) | `kashtheking/class-properties` | `@0.2.0` | Typed constructors for every Roblox class's properties, for type-checking pseudo-instances. |
| [ClientSettings](./client-settings.md) | `kashtheking/local-settings` | `@0.1.0` (deprecated) | A bare-bones store for local (client) settings that fires a Signal when a setting changes. |
| [CountryFlags](./country-flags.md) | `kashtheking/Country-Flags` | `@0.1.0` | Turn a country, region or language code into its flag emoji, and look up a player's region. |
| [GuiHandler](./gui-handler.md) | `kashtheking/gui-handler` | `@1.0.1` | Show and hide ScreenGuis with configurable tweens, and manage them all from one place. |
| [Hitbox](./hitbox.md) | `kashtheking/hitbox` | `@1.0.3` | Object-oriented hitboxes on `GetPartsInPart`, with welding, timed scans and humanoid filtering. |
| [Init](./init.md) |  | WIP | My trusted module loader. Being reworked; the current version ships as a building block. |
| [Mechanic](./mechanic.md) | `kashtheking/mechanic` | `@4.0.3` (deprecated) | A component-style binder that applies logic to CollectionService-tagged instances. |
| [Packet](./packet.md) | `kashtheking/packet` | `@1.0.0` | Buffer-based networking: declare a packet's types once, then fire and respond with typed values. |
| [Predicates](./predicates.md) | `kashtheking/predicates` | `@0.2.3` | Composable predicate functions for instances: attributes, children, characters, players, and combinations. |
| [SoundPool](./sound-pool.md) | `kashtheking/sound-pool` | `@0.1.0` (deprecated) | A pool of positional Sound parts for rapid-fire SFX, such as hits in a fighting game. |
| [StateManager](./state-manager.md) | `kashtheking/state-manager` | `@2.1.1` (deprecated) | A named-state machine with enter/exit callbacks and a Trove per state. |
| [t](./t.md) | `kashtheking/t` | `@1.0.0` | A runtime type checker: build a check once, validate any value with a clear error message. |

</div>

Versions are the ones published to Wally at the time this page was last edited; the [Wally page](https://wally.run/?q=kashtheking) is always current.

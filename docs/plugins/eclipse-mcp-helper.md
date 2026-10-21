---
title: Eclipse Animator MCP Helper
sidebar_position: 8
description: AI helpers that animate live with you inside Eclipse Animator, each with its own name and color.
---

# Eclipse Animator MCP Helper

<div className="library-links">

[Source on GitHub](https://github.com/KashTheKing/library/tree/main/plugins/eclipse-mcp-helper)

</div>

**AI helpers that animate live with you inside Eclipse Animator.**

Eclipse Animator is riftkuro's animation plugin. This add-on gives AI helpers (Claude Code, or anything that speaks
MCP or HTTP) full control of it through the extension API Eclipse publishes, while you keep working: their keyframes
appear in your timeline as they make them, each helper's targets glow in its own color with a name tag, and every edit
sits in your undo history under the helper's name. Run as many helpers as you want; they reserve the tracks they work
on, stay off what you are editing, and only ever undo their own steps.

You need your own copy of Eclipse Animator. Nothing of Eclipse's is included or changed.

## How to use

1. Run `bash plugins/eclipse-mcp-helper/install.sh` (needs Node 18+, Rojo and Claude Code). It installs the Studio
   plugin and adds the `eclipse` MCP server to Claude Code.
2. Open Studio, Eclipse Animator and an animation, and allow the plugin to reach `127.0.0.1` when Studio asks.
3. Open **MCP Helper** from the Plugins tab, then ask Claude Code to animate. Open more sessions, or run
   `node bridge/src/deploy.js --count 3 --task "..."`, for more helpers.

The panel shows every helper and what it is doing, a live activity feed, and buttons to pause all helpers, stop one,
or hide the outlines.

Full setup, the tool list, the webhook and the conflict rules are in the
[README](https://github.com/KashTheKing/library/tree/main/plugins/eclipse-mcp-helper).

## License

FSL-1.1-ALv2.

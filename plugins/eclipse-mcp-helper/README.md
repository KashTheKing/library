# Eclipse Animator MCP Helper

AI helpers that animate with you, live, inside Eclipse Animator (riftkuro's Roblox
Studio animation plugin). Each helper (for example "Claude") gets its own name and color, its edits show up in your
timeline the moment it makes them, its targets glow in the viewport, and you keep working the whole time. Run one
helper or ten.

This is an add-on. It does not include, change or redistribute any of Eclipse Animator's code: it drives Eclipse
through the extension API Eclipse itself publishes (`CoreGui.EclipseAnimatorAPI`, API v6 and newer). You need your
own copy of Eclipse Animator.

## How it fits together

```
Claude Code (helper "Claude") ─┐
Claude Code (helper "Arms")  ──┼─ MCP (stdio) ─► bridge (127.0.0.1:49210) ◄─ long-poll ─ Studio plugin ─► Eclipse API
curl / panel (webhook)  ───────┘                     leases, presence                      outlines, panel
```

- **bridge/**: one small Node process (no dependencies). It keeps the list of helpers, hands out colors, holds track
  leases, and queues commands for each Studio window. The first helper to start launches it automatically.
- **bridge/src/mcp.js**: the MCP server. Every AI session runs its own copy, which joins the bridge as one helper.
- **plugin/**: the Studio plugin (Rojo project, UI in Fusion 0.3 with UI Labs stories). It long-polls the bridge
  (Studio plugins can't host servers), runs each command through Eclipse's API, outlines what each helper touches,
  and tells the bridge what you are doing.

## Set up

1. Install Node 18+, [Rojo](https://rojo.space) and Claude Code.
2. `bash plugins/eclipse-mcp-helper/install.sh` builds the plugin, copies it into Studio's Plugins folder, and adds
   the `eclipse` MCP server to Claude Code (helper name "Claude"; set `ECLIPSE_HELPER_NAME` to change it).
   On Windows: `rojo build default.project.json -o %LOCALAPPDATA%\Roblox\Plugins\EclipseMCPHelper.rbxm`, then
   `claude mcp add --scope user eclipse -- node <path>\bridge\src\mcp.js --name Claude`.
3. Open Studio, Eclipse Animator and an animation. The first time, Studio asks whether the helper plugin may reach
   `127.0.0.1`: allow it. Open **MCP Helper** from the Plugins tab to see the panel.
4. Ask Claude Code to animate, e.g. "Block out a 24-frame idle breath on Workspace.Rig".

### Many helpers at once

- Open more Claude Code sessions: each one joins as its own helper ("Claude", "Claude 2", ...). Use
  `--name Arms` in the MCP command, or the `helper_identity` tool, for custom names and colors.
- Or deploy a team in one line (headless Claude Code runs, logs in `~/.eclipse-mcp-helper/logs`):

  ```bash
  node bridge/src/deploy.js --count 3 --task "Polish the walk cycle on Workspace.Rig; one body area each"
  node bridge/src/deploy.js --names "Arms,Legs,Face" --task "..."
  ```

## Tools each helper gets

| Tool | What it does |
| --- | --- |
| `eclipse_status` | Studio windows, Eclipse version and actions, frame/FPS, undo state, other helpers, what you are doing. |
| `eclipse_call` | Any Eclipse API action directly: full control (`ListTracks`, `SetKeyframe`, `Batch`, folders, `ForwardInput`...). |
| `eclipse_list_tracks`, `eclipse_list_properties` | What is on the timeline and which property tracks an object supports. |
| `eclipse_add_object` | Put a rig, part, light or camera on the timeline. |
| `eclipse_set_keyframe`, `eclipse_set_easing` | Key a joint or property at a frame; `offset` bends a joint from its current C0. |
| `eclipse_batch` | Many edits as one atomic step: one undo for you. |
| `eclipse_command` | Press any Eclipse command: playback, stepping, copy/paste, delete, reverse, onion skin, save, export. |
| `eclipse_history` | Undo/redo the helper's own last step (never yours). |
| `studio_find_rigs`, `studio_read_pose`, `studio_read_animation`, `studio_selection` | Read rigs, joints (C0/C1/Transform), saved KeyframeSequences in AnimSaves, and your selection. |
| `helper_focus`, `helper_claim`, `helper_release`, `helper_presence`, `helper_identity` | Presence and coordination. |

Values travel as JSON: instances as `{"$inst":["Workspace","Rig","Head"]}` or `"Workspace.Rig.Head"`, CFrames as
`{"$cf":[12 numbers]}` or `{"$cf":{"p":[x,y,z],"r":[rx,ry,rz]}}` (degrees), and `$v3`, `$v2`, `$c3`, `$udim2`, `$enum`.

## Working together without stepping on each other

- **Identity:** every edit lands in Eclipse's undo history as "Claude: SetKeyframe Head @12" (or the helper's batch
  name), and what a helper touches is outlined in its color with a name tag for a few seconds.
- **Track leases:** an edit reserves its tracks for that helper for 20 seconds (`helper_claim` for longer). Another
  helper editing the same track gets a clear "Claude is working on Workspace/Rig/Head" refusal and moves on.
- **You come first:** while you are editing (an Eclipse edit in the last 8 seconds), helpers can't key the parts you
  have selected, and commands that act on Eclipse's shared selection (delete, paste, reverse...) wait.
- **Safe undo:** a helper can only undo the newest step if it is its own, so it never undoes your work.
- **Your controls:** the panel can pause all helpers, stop or resume one helper, and hide the outlines.
- Eclipse's own `BeginBatch`/`EndBatch` are refused because they are shared by everyone; `Batch` does the same job
  atomically.

## Webhook

Anything on this computer can drive Eclipse with one HTTP request, using the token in `~/.eclipse-mcp-helper/token`:

```bash
curl -s http://127.0.0.1:49210/hook -H "Authorization: Bearer $(cat ~/.eclipse-mcp-helper/token)" \
  -H "Content-Type: application/json" \
  -d '{"name":"Panel","op":"eclipse.command","args":{"command":"TogglePlayback"}}'
```

`GET /events` (same header) streams live activity as server-sent events. Ops: `eclipse.invoke` (`{action, request}`),
`eclipse.command`, `eclipse.history`, `eclipse.status`, `studio.rigs`, `studio.pose`, `studio.animation`,
`studio.selection`, `helper.focus`.

## Security

The bridge listens on 127.0.0.1 only. Helper and webhook calls need the token (a 0600 file only you can read).
Requests from web pages are refused (any `Origin` or `Sec-Fetch-Site` header, or a Host other than 127.0.0.1/localhost),
so a website can't reach it. The Studio plugin only ever contacts 127.0.0.1, and its outlines live in CoreGui, so
nothing is saved into your place.

## Develop

```bash
cd bridge && npm test                                   # bridge, leases, webhook and MCP server
rojo build default.project.json -o build/EclipseMCPHelper.rbxm
lune run test/run.luau build/EclipseMCPHelper.rbxm      # the built plugin's modules under Lune
rojo serve stories.project.json                         # UI Labs stories in ReplicatedStorage.EclipseMCPHelperUI
```

## License

[FSL-1.1-ALv2](LICENSE.md). Fusion is MIT (its license is in `plugin/Packages/Fusion`). Eclipse Animator belongs to
riftkuro and is not part of this project.

# Flashback

The open-source core of [Flashback](https://kashtheking.com/flashback/): record gameplay on the server into a compact binary replay and play it back on lightweight proxies, on the client or inside Roblox Studio, with play, pause, seek and variable speed. MIT licensed.

Documentation and API reference: **https://kashtheking.com/flashback/**

The **Flashback Studio plugin** (installer, one-click recording, replay browser, Moon Animator export UI) is proprietary and not part of this package. It is coming soon to the Creator Store.

## Installation

### Studio Wally

Using the [Studio Wally plugin](../../../plugins/studio-wally):

1. Open the widget
2. Search `kashtheking/flashback`
3. Click the download button and choose "Shared module"

### Wally

Add this to the `[dependencies]` section of your `wally.toml`:

```toml
Flashback = "kashtheking/flashback@1.0.0"
```

The `Tests` folder can be deleted from production builds.

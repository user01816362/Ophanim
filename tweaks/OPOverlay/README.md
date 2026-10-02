# OPOverlay — example user tweak (floating panel)

Proves the tweak pipeline end to end: a hand-built `.dylib` that draws a
draggable floating panel inside any hosted app, installed and managed
entirely through MCP. Pure C against the ObjC runtime (no UIKit import, no
Xcode, no new deps) — compiles with the command-line tools alone.

## Build

```sh
cc -arch arm64 -target arm64-apple-ios16.0-macabi -dynamiclib overlay.c \
   -framework Foundation -o OPOverlay.dylib
```

Expect `platform MACCATALYST` (`vtool -show-build`). The dylib links only
Foundation/libSystem/libobjc; every UIKit class is resolved at runtime with
`objc_getClass`, so there is nothing to headers against.

## Install (on a nightly containing the UserPlugins loader)

```json
// 1. copy into the app's tweak store (dryRun previews first)
{"tool": "add_tweak", "bundleID": "<bid>", "path": "/path/to/OPOverlay.dylib", "dryRun": false}
// 2. sync into the app (rewrites Frameworks/UserPlugins + re-signs)
{"tool": "resync_tweaks", "bundleID": "<bid>"}
// 3. relaunch — the Galgal runtime dlopens UserPlugins/*.dylib at startup
{"tool": "launch_app", "bundleID": "<bid>"}
// 4. prove it
{"tool": "screenshot", "bundleID": "<bid>", "annotate": true}
```

Remove with `remove_tweak` + `resync_tweaks` + relaunch. Disable without
deleting via `set_tweak_enabled` (`.disabled` convention — the loader skips it,
mirroring the store scan, so GUI and loader never disagree).

## What it does

Constructor defers to the main queue, then adds a 250×132 panel to the key
window: title, host bundle id, drag (pan gesture via a runtime-created target
class), and an X button. No key-window theft, no window-level change, no
persistence. Close with X; relaunch re-shows while installed.

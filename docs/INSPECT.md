# InspectProtocol (Agent Mode)

Inspect lets an AI operator see and touch a hosted app like a user does: UI-tree reads,
screenshots, and taps. Deliberately separate from the capture engine (OphanimCore):
no hooks, no interposes, no code patching — an in-process reader plus the product's own
touch path, talking to the host over files.

## Activation

Per app, `agentMode` (default false) in the Hacking pane, persisted in `OPConfig`
(`OphanimCore/policy/OPConfig.swift`). The in-process pump only runs when on
(`Galgal/Galgal/Inspect/InspectCommandPump.swift` live gate); MCP refuses when off
(`Ophanim/Core/MCP/InspectGate.swift`). Turning ON needs a relaunch (boot latch);
turning OFF stops serving within one poll. The redaction consent surface is owned
separately — the flag is `inspectDisableRedaction` (default redact).

## Wire

- Guest (Galgal target): `Galgal/Galgal/Inspect/` — `InspectRequest` (protocol types,
  compiles into guest+host so the sides cannot drift), `Inspector` (tree),
  `InspectorScreenshot` (JPEG), `InspectorActivator` (tap via `Toucher.touchcam`;
  began now, ended next main turn — same-tick phases collapse), `InspectCommandPump`
  (0.5 s main-runloop poll, common modes). Booted from `GalgalLoader` on the main
  queue — one config read and out unless opted in.
- Channel: `OPPaths.logDirectory(bundleID)/inspect-cmd.json` (host writes, guest claims
  by atomic rename — never read-then-delete, so a slow op never runs twice) and
  `inspect-rsp-<id>.json` (guest writes, host deletes after reading). No new
  entitlement, no TCC prompt. One client at a time (host-side lock — per-process only;
  see `docs/RISKS.md`). Orphaned responses older than 10 minutes are swept.
- Liveness: while serving, the guest rewrites `inspect-pump-alive` per minute. Refusals
  come in four distinct voices (not installed / not running / Agent Mode off / pump
  silent), each naming its own fix.
- Host (app target): `Ophanim/Core/MCP/Services/InspectService.swift` (`InspectControl`:
  60 s bounded wait, stale-command withdrawal on timeout) and
  `Ophanim/Core/MCP/Tools/InspectTools.swift` (17-tool catalog + routing).

## Commands

| op | params | response |
|---|---|---|
| `uiTree` | `mode` full/compact, `filter`, `rootId`, `depthLimit` 1...24 + `nodeLimit` 1...2000 | `tree` (positional ids `0.2.1`), `truncated` + `truncatedBy` when caps cut |
| `screenshot` | - | `imageBase64` JPEG (longest edge 1280, q0.85), `width`, `height` |
| `tap` | `elementId` (preferred) or normalized `x`/`y` | `acted`, `targetClass` (key window only; began accepted + ended queued, not delivered) |
| `swipe` | `x1/y1/x2/y2` normalized, `steps` 1...20 | `acted`, `targetClass` |
| `setText` | `elementId`, `text` | `acted`, `targetClass` (direct set + change notification; no focus side effects) |
| `classes` | `filter`, `limit` | `classes` + `totalCount` (C enumeration — Swift must never malloc/free the buffer) |
| `classDetail` | `className` | methods/ivars/properties/protocols/superclasses (all copy/free pairs stay in C) |
| `element` | `elementId` | subtree + `superclasses` chain + `viewController` |

MCP serves the tree as JSON *text*, not nested structured content: real trees nest 20+
levels and exceed client object-depth limits. Element ids resolve by re-walking; a
moved/vanished view fails with "take a fresh tree", never a guessed tap. Every failure
writes a failure response — the host waits on the response file, so silence is "not done".

## Redaction (existing behavior)

Default on: secure text fields report masked text in the tree, their window-space frames
are filled black pre-encode (masked pixels never exist). `WKWebView` content is opaque
in-process — a container node, never invented. Keychain/crypto capture is out of scope
for this channel. The consent UX for raw capture is owned separately.

## MCP tools

`uitree_read`, `screenshot` (read-only); `tap_element`, `swipe`, `set_text` (touch the
app; no dry run — irreversible effects possible). All refuse with "Agent Mode is not
enabled" when the app never opted in.

## Snapshot timeline

`inspect_snapshot` pins one tree (+ optional JPEG) under `Logs/<bundleID>/snapshots/`
(newest 20 kept, pruned on capture, purged on uninstall). `inspect_timeline` lists
entries; `inspect_diff` compares into named events (`class_flip`, `content_change`,
`nodes_added/removed`, `subtree_rebuild`, `scroll`, `count_delta`); same-mode/same-filter
pairs only, budget-cut pairs marked `partial`. `inspect_clear_snapshots` deletes the
timeline (dryRun-default). Gestures take `snapshot: none|pre|post|both` (default none —
each leg costs a transaction).

## Bookmarks

`bookmark_add` (class/symbol by name; element needs a pinned snapshot — pass one or a
fresh capture is taken), `bookmark_note`, `bookmark_move` (dryRun-default; unknown ids
fail before mutation), `bookmark_list` (staleness hints; `checkFresh` re-reads live),
`bookmark_remove` (dryRun-default; groups free members, snapshots unpin). Stored as
reference-not-value, capped — never in the settings plist.

## Lifecycle (nothing grows forever)

- Launch: `HostedApp.launch` summarizes the previous run's crash, sweeps logs (when
  enabled), then sweeps unpinned snapshots — each run starts with a clean timeline;
  pinned entries survive with their proof.
- Keep-N: captures auto-prune to newest 20 unpinned; pins are spared and bounded.
- Data wipe (`clear_container` data scope): container + timeline + bookmarks together.
- Uninstall: log dirs (snapshots inside) + bookmarks file are ungated inventory — no
  reinstall inherits another install's marks.

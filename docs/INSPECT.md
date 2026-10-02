# Inspect Protocol (Agent Mode)

Inspect lets an AI operator see and touch a hosted app like a user does:
UI-tree reads, screenshots, and gestures. Deliberately separate from the
capture engine (OphanimCore): no hooks, no interposes, no code patching —
an in-process reader plus the product's own touch path, talking to the host
over files.

## Activation

Per app, two switches in the Hacking pane, persisted in `OPConfig`
(`OphanimCore/policy/OPConfig.swift:235-236`):

- `agentMode` (default false). The in-process pump only runs when on
  (`Galgal/Galgal/Inspect/InspectCommandPump.swift:26-28`); MCP refuses
  when off via the single gate `InspectGate.requireLive`
  (`Ophanim/Core/MCP/Tools/Inspect/InspectTools.swift:43-47`).
- `inspectDisableRedaction` (default false = redact). Over MCP the explicit
  flag is the consent; the GUI path requires accepting the risk alert.
  [unverified: GUI alert location — flag definition is
  `OPConfig.swift:236`, consent UX not re-verified this pass.]

Boot latch: turning Agent Mode ON needs a relaunch (the pump boots once
from `GalgalLoader` on the main queue — one config read and out unless
opted in); turning it OFF stops serving within one poll (live gate in
`poll()`). The redaction flag rides into `execute` per poll instead of
re-reading the plist per op (`InspectCommandPump.swift:72-73`).

## Wire

- Guest (Galgal target): `Galgal/Galgal/Inspect/` — `InspectRequest`
  (protocol types, compiles into guest+host so the sides cannot drift),
  `Inspector` (tree), `InspectorScreenshot` (JPEG), `InspectorActivator`
  (tap via `Toucher.touchcam`; began runs now, ended queues on the next
  main turn because same-tick phases collapse), `InspectCommandPump` (0.5 s
  main-runloop poll, common modes — `InspectCommandPump.swift:50-51`).
- Channel: `OPPaths.logDirectory(bundleID)/inspect-cmd.json` (host writes,
  guest claims by atomic rename — never read-then-delete, so a slow op
  never runs twice) and `inspect-rsp-<id>.json` (guest writes, host deletes
  after reading). No new entitlement, no TCC prompt. One client at a time
  (host-side lock — per-process only; see `docs/RISKS.md`). Orphaned
  responses older than 10 minutes are swept.
- Liveness: while serving, the guest rewrites `inspect-pump-alive` per
  minute (`InspectCommandPump.swift:75`, name in
  `InspectRequest.swift:193`). Refusals come in four distinct voices (not
  installed / not running / Agent Mode off / pump silent), each naming its
  own fix; a stale heartbeat with Agent Mode on names relaunch explicitly
  (`InspectService.swift:120-131`).
- Host (app target): `Ophanim/Core/MCP/Services/InspectService.swift`
  (`InspectControl`: 60 s bounded wait, stale-command withdrawal on
  timeout) and `Ophanim/Core/MCP/Tools/Inspect/InspectTools.swift`
  (18-tool catalog + routing, `inspectToolNames`,
  `InspectTools.swift:740-748`).

## Commands

| op | params | response |
|---|---|---|
| `uiTree` | `mode` full/compact, `filter` substring, `rootId` element id (subtree read with globally positional ids; unresolvable roots fail stated), `depthLimit` 1...24 + `nodeLimit` 1...2000 (narrow-only agent caps) | `tree` (positional ids `0.2.1`, budgets: depth 24, 2000 nodes), `truncated` + `truncatedBy:["depth"/"nodes"]` when caps cut. Compact collapses layout-only single-child UIViews; filter keeps matches + ancestors |
| `screenshot` | — | `imageBase64` JPEG (longest edge 1280, q0.85), `width`, `height` [unverified: exact size/quality constants not re-read this pass] |
| `tap` | `elementId` (preferred) or normalized `x`/`y` | `acted`, `targetClass` (key window only; `acted` means began accepted and ended queued, not delivered) |
| `swipe` | `x1/y1/x2/y2` normalized, `steps` 1...20 (default 8) | `acted`, `targetClass` (began accepted; moves interpolated with runloop spins — `InspectTools.swift:135-157`) |
| `setText` | `elementId`, `text` | `acted`, `targetClass` (direct set + change notification; no focus side effects) |
| `pick` | normalized `x`/`y` (required, 0...1), `mode` | `elementId` + class (+ owning VC). HitTest-independent; disabled views resolve (`InspectTools.swift:115-133`) |
| `classes` | `filter`, `limit` 1...2000 | `classes` names + `totalCount` loaded. Enumeration runs in C (`InspectRuntime.m`): Swift must never malloc/free the class-list buffer — balancing that autoreleasing C return as an object aborts (reproduced SIGTRAP, fixed by keeping it in ObjC) |
| `classDetail` | `className` | method/ivar inventory: `methods`/`classMethods` (`sel`, explicit `args`, `ret` code), `ivars`, `properties`, `protocols`, `superclasses`, `truncated`. All copy/free pairs stay in C; own members only |
| `element` | `elementId` (+ `mode` — ids resolve only in the mode whose walk produced them, default full) | full `tree` subtree + `superclasses` chain + `viewController` (responder chain). Mode mismatch fails stated (`InspectTools.swift:728-736`) |

MCP serves trees/nodes as JSON *text*, not nested structured content: real
trees nest 20+ levels and exceed client object-depth limits (hit at 32 on
first live use). Same bytes, flat envelope
(`InspectTools.swift:50-76`, `193-212`, `214-234`).

Element ids resolve by re-walking; a moved/vanished view fails with "take a
fresh tree", never a guessed tap. Every failure writes a failure response —
the host waits on the response file, so silence always means "not done".

## Node labels (framework / layer / scene)

Each `InspectNode` carries label-only annotations
(`Galgal/Galgal/Inspect/InspectRequest.swift:152-174`): `framework`
(owning UI framework, inherited down subtrees; nil = indistinguishable
UIKit, never a guess), `layer` (backing-layer class only when not a plain
`CALayer`, else nil — payloads stay small). Responses name
`frameworksDetected` (instance-proven union over the walked tree),
`frameworkEvidence` (framework → ≤5 class/VC names), `rnArch`
(`paper`/`fabric`/`both`/`unknown`, uiTree only), and `scene` (key-window
`"<sceneId>:level<n>:key..."`) (`InspectRequest.swift:101-111`; guest fills
them in `Inspector.snapshot`/`keyWindowFramework`,
`Inspector.swift:109-215`). Rule: nil-means-unknown; old timelines decode
via nil defaults. Full rationale:
`docs/DECISIONS/0011-framework-layer-scene.md`.

## Redaction states

Default on: secure text fields report masked text in the tree, their
window-space frames are filled black pre-encode (masked pixels never
exist). `WKWebView` content is opaque in-process — a container node, never
invented. Keychain/crypto capture is out of scope for this channel.

Three states an operator must distinguish (all surfaced per response as the
`redacted` flag — `InspectTools.swift:66-69`, `84-87`):

1. **Redacted (default).** Tree text masked, secure frames blacked.
2. **Accepted-raw** (`inspectDisableRedaction:true` = the consent).
3. **Frozen at capture.** Snapshots store the redaction state in the
   manifest (`SnapshotStore.swift:66-67`); reading with redaction later
   disabled must not unmask stored trees/JPEGs. `set_text` text is never
   stored (length only — `captureTreeSnapshot` records `textLength`,
   `InspectTools.swift:168-172`).

Redaction-mismatched diff pairs still compare classes but mark the pair
`partial` ("text is unreliable, classes still comparable",
`SnapshotStore.swift:432-434`).

## MCP tools

Read-only: `uitree_read`, `screenshot`, `inspect_pick`,
`inspect_classes`, `inspect_element`, `inspect_class_detail`
(`MCPServer.swift:36-48`). Touch the app (no dry run — irreversible
in-app effects possible): `tap_element`, `swipe`, `set_text`.
`set_text` needs `elementId` ("take a tree, pick the field");
`tap_element` needs `elementId` (preferred) or both x+y in 0...1;
coordinates accept Int or Double (`InspectTools.swift:89-180`). All refuse
with "Agent Mode is not enabled" when the app never opted in.

## Snapshot timeline

`inspect_snapshot` pins one tree (+ optional JPEG sidecar via
`withScreenshot`) as a timestamped entry under `Logs/<bundleID>/snapshots/`
(`InspectTools.swift:236-277`). Newest 20 kept (`keepSnapshots`,
`SnapshotStore.swift:90`), oldest evicted whole-stem (`.json` + `.jpg`) on
capture (`SnapshotStore.swift:146`, `182-194`); purged on uninstall with
the rest of the log dir. Timeline listings carry manifests only — trees
stay on disk until a diff (`manifestSummary`, `InspectTools.swift:633-651`).

`inspect_timeline` lists entries (optional `trigger` filter, `limit`≥1)
with a latest-pair diff summary (event + flip counts,
`InspectTools.swift:279-300`). `inspect_diff` compares two entries
(defaults: `to` = latest, `from` = its predecessor) into named events:
`class_flip`, `layer_flip` (same slot+class, both layers non-nil and
different; both-nil old timelines never fire — `SnapshotStore.swift:393-395`),
`content_change`, `nodes_added/removed` (with samples), `subtree_rebuild`,
`scroll` (dx/dy), `count_delta` (`SnapshotStore.swift:313-436`).
`inspect_clear_snapshots` deletes the timeline (dryRun-default,
`InspectTools.swift:339-349`).

`tap_element`, `swipe`, and `set_text` take `snapshot: none|pre|post|both`
(default none) to bracket the op; pre/post ids come back in the response
for `inspect_diff` (`SnapshotCaptureArg`, `InspectService.swift:137-155`;
shared shape `withSnapshots`, `InspectTools.swift:18-26`). Each leg costs a
full tree transaction. Gesture-adjacent captures record an op ref
(element/coords/steps/textLength), manual captures record mode/filter/root/
caps/scene pairing keys (`InspectTools.swift:607-631`, `259-268`).

Diffs pair only same-mode/same-filter/same-root/same-caps/**same-scene**
snapshots — cross pairs refuse stated (`InspectTools.swift:325-331`); the
manifest carries the pairing keys plus informational `scene`/`frameworks`
(`SnapshotStore.swift:49-84`). Budget-cut pairs are marked `partial`
("a budget-cut tree is partial input", `SnapshotStore.swift:426-430`).

## Snapshot pins

Pins keep snapshots alive across sweeps. A pin is created implicitly when a
bookmark references an element snapshot: pass an existing snapshot id, or a
fresh capture is taken — refused when the pin cap is reached ("pass an
existing snapshot instead", `InspectTools.swift:377-400`). Bookmark removal
unpins; unpinned snapshots become sweepable
(`InspectTools.swift:591-600`).

## Bookmarks

`bookmark_add` pins a finding with a comment: a runtime class or binary
symbol (stable by name) or a tree element (pinned to a timeline snapshot,
since positional ids die with their tree). Element bookmarks in a
non-default mode are pinned against that mode's walk ("element ids only
resolve in the mode whose walk produced them",
`InspectTools.swift:382`). Enforces the bookmark cap ("remove some first",
`InspectTools.swift:357-358`). `bookmark_note` comments/tags (idempotent —
same contract as the old guide [unverified: handler not re-read this
pass]); `bookmark_move` files into named groups (dryRun-default; unknown
ids fail stated before anything changes — no silent partial membership,
`InspectTools.swift:463`; groups auto-create on reference,
`InspectTools.swift:653-663`). `bookmark_list` reads with a staleness hint
per element (`stale`/`staleReason`: ok, snapshot-gone, class-gone,
hierarchy-changed — `InspectTools.swift:523-559`; `checkFresh` re-reads the
live tree to verify). `bookmark_remove` deletes (dryRun-default; groups
free their members, snapshots unpin and become sweepable). Stored as
reference-not-value in `AgentBookmarks/<bid>.json` (capped), never in the
settings plist.

## Lifecycle (nothing grows forever)

- Launch: `HostedApp.launch` sweeps unpinned snapshots, so each run starts
  with a clean timeline; pinned entries (referenced by bookmarks) survive
  with their proof.
- Keep-N: captures auto-prune to the newest 20 unpinned; pins are spared
  and bounded by the pin cap.
- Data wipe (`clear_container` data scope): container + timeline + bookmarks
  go together (`ContainerTools.swift:140-177`).
- Uninstall: log dirs (snapshots inside) + the bookmarks file are ungated
  inventory, so no reinstall inherits another install's marks.

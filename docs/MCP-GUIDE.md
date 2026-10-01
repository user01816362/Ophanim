# MCP Guide — Ophanim Agent Surface

55 tools, stable names, deterministic (alphabetical) order. Cache the `tools/list`
result: the set is fixed per process (`listChanged: false`, `ttlMs: 300000`). No
pagination — one page, cursors ignored, re-list from scratch. No prompts, resources,
sampling, or elicitation: tools-only is the whole surface, by design.

Transport: `Ophanim --mcp` (stdio) or HTTP `127.0.0.1:20033` (loopback by default).
Same catalog both ways. The stdio shape is the textbook MCP pattern, not a quirk: the
client spawns one `Ophanim --mcp` child process per connection (headless, no GUI/dock
icon), and pipes are per-process by nature. Seeing two `--mcp` children next to the
open GUI app is normal — one per connected client. State shared across those
processes is file-backed (settings plists, NDJSON logs, the inspect command slot),
so every child and the GUI read the same truth; in-memory state does NOT cross
processes (the inspect slot's `NSLock` guards one process only — two concurrent
children can still collide on the slot; see `docs/RESIDUAL-RISK.md`). Rate limit 120/min per tool (wait out the stated retry, don't
hammer). Every tool result carries `structuredContent` mirrored as text JSON — read
either. Failures are `isError: true` with a self-correcting message — except unknown
tool *names*, which also return `isError` (friendlier than the spec's `-32602`, kept
deliberately; fix the name, don't retry blindly).

Conventions used below: **R** read-only, **D** destructive, **I** idempotent.
`dryRun` defaults true on every mutating tool except pure setters and tap/swipe —
preview first, then re-call `dryRun: false`. Tool names/args/defaults live in code
(`mcpTool` + `toolDefinitions`); this guide reproduces semantics, never parameters.

## First calls (proof you read this)

1. `list_apps` → bundle IDs. 2. `get_config` before any mutation. 3. `dryRun` preview
before any execute. An agent that mutates before reading config has not read the guide.

## Families

**Inventory** — `list_apps` (R/I: installed apps + categories + live `running` flag from the
single shared liveness definition, so status and the inspect gate never disagree), `analyze_app` (R/I:
behavior/privacy rollup from events, plus a `crash` section: the previous run's
explanation (`last-crash.json`, written at launch before the sweep) — run identity,
event count, recorded cause + detail file when one exists, or an explicit "no crash
artifact: clean quit or silent kill (indistinguishable)" when nothing does. A clean
quit never files a false crash.), `app_imports` (R/I: hookable TLS/crypto symbols),
`find_symbols` (R/I: keyword over binary symbols for hook targets), `list_classes`
(R/I: static class/selector inventory, limit ≤2000), `list_jailbreak_detectors` (R/I:
bypassable SDK ids).

**Events** — `query_events` (R/I: history by category/search/limit), `tail_events`
(R/I: live poll — pass back `cursor` as `since`, ms epoch; `since: 0` = latest batch,
not history).

**Config** — `get_config` (R/I: `instrumentation` vs `hosting` groups), `set_config`
(field-level writes; unknown keys rejected with did-you-mean; capture settings apply
live, hooks/strategy need relaunch). Read the projection before writing it.

**Hooks/Rules** — `list_presets`, `apply_preset` (merge block-trackers/fake-idfv/fake-idfa),
`set_rules` (full replace; script rules read/SET ctx), `set_objc_hooks` (void methods,
msgSend-dispatched only), `set_swift_hooks` (vtable only; -O devirtualizes the rest —
use inline), `set_inline_hooks` (arm64; gated on `enableInlineHooks`; address/symbol/
module+offset/module+signature locating; renderArgs/renderReturn for ObjC values).
Hook writes are immediate full-replacements with no dry run — say what you replace.

**Lifecycle** — `install_app` (R: .ipa in; Galgal always injected, no prompt),
`launch_app` (spawns the app with current config), `uninstall_app` (D/I: preview/execute
share one inventory; `purgeData` also deletes the resolved container).

**Tweaks** — `list_tweaks` (+recursive), `inspect_tweak` (run BEFORE add: arch/platform/
links/signature gate), `add_tweak`/`move_tweak`/`remove_tweak`/`set_tweak_enabled`
(dryRun), `tweak_folder` (create/rename/remove; rename then resync), `resync_tweaks`
(idempotent repair after hand edits), `get_keymap` (read-only by design).

**Logs/Container** — `get_log_path` (authoritative log location + file sizes),
`clear_logs` (D/I dryRun, exact paths+bytes), `container_info` (resolved path, size,
profiles — never composed), `list/create/switch/remove_profile` (dryRun; removing the
active profile is refused; switch displaces live state), `clear_container` (D/I dryRun: caches/data/
keychain scopes; data scope also wipes snapshots+bookmarks), `backup_container`/
`restore_container` (D dryRun; ditto zips; restore refuses while running),
`set_injection_strategy` (D dryRun; poll-verified, `verified:true` only when measured).

**Inspect Agent-Mode** (full protocol: `docs/INSPECT.md`) — gate: app must have
`agentMode` on (turning it ON needs a relaunch - boot latch; turning it OFF stops
serving within one poll). `uitree_read` (R/I: tree
as JSON *text*, `truncated` flag, filter keeps matches+ancestors), `screenshot` (R/I:
1280px JPEG image block, secure frames blacked pre-encode), `tap_element` (D: began+ended
through the app's own touch path; elementId OR x/y; irreversible in-app effects possible —
no dry run exists), `swipe` (D: began/moves/ended, steps 1...20), `set_text` (direct set
+ change notification, no focus side effects; tap first when the app needs them),
`inspect_classes` (R/I: runtime enumeration in C, filter-first, limit ≤2000, total
reported), `inspect_element` (R/I: subtree + superclass chain + owning VC).
Element ids are positional per-walk, same-mode only — a moved view fails with "take a
fresh tree", never a guessed tap. `redacted:false` means accepted-raw
(`inspectDisableRedaction:true` IS the consent, GUI-alert equivalent).

**Snapshots** — `inspect_snapshot` (pins tree + optional JPEG; keep newest 20, prune on
capture — hence D-marked, honestly), `inspect_timeline` (metadata list + latest-pair
summary; trees stay on disk), `inspect_diff` (named events: `class_flip`,
`content_change`, `nodes_added/removed`, `subtree_rebuild`, `scroll`, `count_delta`;
same-mode/same-filter pairs only; budget-cut or redaction-mismatched pairs marked
`partial`), `inspect_clear_snapshots` (D/I dryRun). `tap/swipe/set_text` take
`snapshot:none|pre|post|both` (default none — each leg costs a transaction) and return
the ids for diffing. Launch sweeps unpinned snapshots (clean run); pins survive via
bookmarks. Snapshots freeze redaction at capture; `set_text` text is never stored.

**Bookmarks** — `bookmark_add` (class/symbol by name; element needs elementId + pinned
snapshot — pass one or a fresh capture is taken), `bookmark_note` (comments/tags,
idempotent), `bookmark_move` (dryRun; unknown ids fail before mutation; groups
auto-create), `bookmark_list` (kind/tag/group filters; element staleness via
`stale/staleReason`, `checkFresh` re-reads the live tree), `bookmark_remove` (D/I
dryRun; groups free members, snapshots unpin). Reference-not-value, capped, own store —
uninstall/data-wipe deletes it with the app.

## Recipes

- **First instrumentation:** list_apps → get_config → set_config → launch_app →
  tail_events (cursor loop).
- **Hook loop:** app_imports → find_symbols → set_*_hooks → relaunch (new hooks need it).
- **Tweak iteration:** inspect_tweak → add_tweak (dryRun preview) → resync_tweaks.
- **UI investigation:** agentMode → uitree_read → tap/swipe (snapshot:both) →
  inspect_diff → bookmark_add → inspect_element for depth.
- **Container A/B:** list_profiles → create/switch (refuses while running) → clear as needed.
- **Uninstall:** uninstall_app dryRun → read preview → dryRun:false (+purgeData only deliberately).

## Redaction & consent

Default-redacted everywhere. Raw capture requires explicit consent per surface:
Inspect via `inspectDisableRedaction:true`; capture fields via `redactionKeys`. Secure
tree text arrives as `•••`, secure pixels never exist. Stored snapshots never upgrade
state. Secrets content (keychain values) is not readable, only deletable — captured
*ops* metadata is not stored *secret* content; keep that line.

## Errors (verbatim, self-correct)

`bundleID is required` · `app not installed: <bid>` · `app not running: <bid> -
launch it first (launch_app), then retry` · `Agent Mode is not enabled for <bid>; turn
it on in the app's Hacking settings, then relaunch the app` · `take a fresh tree`
(stale elementId) · `did you mean…` (unknown set_config key) · `rate limited: <tool> …
wait <N>s` · `inspect timed out after 60s - guest pump silent since <t> - relaunch the
app with Agent Mode on` (or `no pump heartbeat` when the pump never beat)
Liveness ("is the app running") is one shared definition for all tools
(`InspectControl.isAppRunning`): NSWorkspace match OR fresh pump heartbeat (<150 s)
OR flowing capture writes (<120 s). A client-spawned server child can see a different
application list than a shell-spawned one, so a bare workspace check is never the
verdict on its own.
Timeouts withdraw the command (a late tap never fires twice); orphan responses older
than 10 min are swept; the slot is one client at a time.

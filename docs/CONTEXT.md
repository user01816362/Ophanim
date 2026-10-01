# Context & Glossary

Normative spellings. Every ADR and header comment must use these.

| Term | Meaning |
|---|---|
| embedded | Galgal.framework loaded in the hosted app |
| sibling | OphanimAgent.dylib injected alongside, second LC_LOAD_DYLIB |
| interpose | DYLD_INTERPOSE rebinding (use `OPInterpose.h`, never redefine) |
| swizzle | ObjC method_exchange (high-level FS via NSFileManager) |
| vtable patch | Swift/static-dispatch hook |
| inline hook | Tier-3 arm64 machine-code patch + trampoline arena |
| ring producer/consumer | `op_ring_emit` (any-context, no alloc/lock/ObjC) → consumer thread → `OPRingBridge.emitKind` |
| disposition | observe / block / delay / fault / modify / replace / script |
| capture layer | network / keychain / crypto / filesystem / process / device |
| bypass-vs-logging | pinning/JB bypass changes app behavior to observe it; always an explicit tradeoff, recorded in an ADR |

Ownership: Keychain = Galgal-owned. FS raw POSIX = sibling-only
(`OPHooksFSRaw.m`, `-D OPHANIM_SIBLING`). No-double-interpose rule.

## MCP agent surface (ported from OLD MCP-GUIDE)
- One `--mcp` child per connected client is normal (pipes are per-process).
  State shared across children/GUI is file-backed (settings plists, NDJSON
  logs, inspect slot); in-memory state does NOT cross processes.
- Rate limit 120/min per tool: wait out the stated retry, don't hammer.
- Every result carries `structuredContent` mirrored as text JSON — read either.
- Failures are `isError: true` with self-correcting messages, except unknown
  tool names (also `isError`, friendlier than `-32602` — fix the name).
- `dryRun` defaults true on mutating tools (except pure setters and tap/swipe):
  preview first, then re-call `dryRun: false`.
- First calls: `list_apps` → bundle IDs, `get_config` before mutating.

## MCP families (ported from OLD MCP-GUIDE)

60 tools, stable names. Cache `tools/list` (`listChanged: false`,
`ttlMs: 300000`). One page, no pagination; no prompts/resources/sampling —
tools-only by design. Transport: `Ophanim --mcp` stdio (one child per client
is normal; shared state is file-backed — settings, NDJSON, inspect slot).
HTTP only when launched with `--port` (opt-in, never default).

Conventions: **R** read-only, **D** destructive, **I** idempotent. Tool
names/args live in code (`MCPServer.toolDefinitions`); this reproduces
semantics, never parameters.

- **Inventory** — `list_apps` (R/I + live `running`), `analyze_app` (R/I +
  `crash` section: previous run's explanation or explicit "no crash
  artifact"), `app_imports`, `find_symbols`, `list_classes` (R/I: live
  runtime classes when Agent Mode runs, else static strings, limit ≤2000),
  `list_jailbreak_detectors`.
- **Events** — `query_events` (R/I), `tail_events` (R/I live poll, `since`
  ms epoch; `since: 0` = latest batch).
- **Config** — `get_config` (R/I), `set_config` (field-level; unknown keys
  rejected with did-you-mean; capture applies live, hooks/strategy need
  relaunch).
- **Hooks/Rules** — `list_presets`, `apply_preset`, `set_rules` (full
  replace), `set_objc_hooks` (void, msgSend only), `set_swift_hooks`
  (vtable only), `set_inline_hooks` (arm64, `enableInlineHooks` gate).
  Hook writes are immediate full-replacements, no dry run.
- **Lifecycle** — `install_app` (.ipa in, Galgal always injected),
  `launch_app`, `uninstall_app` (D/I dryRun; `purgeData` deletes container).
- **Tweaks** — `list_tweaks`, `inspect_tweak` (run BEFORE add),
  `add/move/remove_tweak`, `set_tweak_enabled`, `tweak_folder`, `resync_tweaks`,
  `get_keymap` (read-only by design).
- **Logs/Container** — `get_log_path`, `clear_logs` (D/I dryRun),
  `container_info`, `list/create/switch/remove_profile` (dryRun; active
  refused; switch refuses while running), `clear_container` (D/I dryRun;
  data scope also wipes snapshots+bookmarks), `backup/restore_container`
  (D dryRun; restore refuses while running), `set_injection_strategy`
  (D dryRun; poll-verified).
- **Inspect Agent-Mode** (full protocol: `docs/INSPECT.md`) — gate: app must
  have `agentMode` on (ON needs relaunch, OFF stops within one poll).
  `uitree_read`, `screenshot` (R/I); `tap_element`, `swipe`, `set_text` (D,
  no dry run — irreversible in-app effects possible); `inspect_classes`,
  `inspect_element`, `inspect_class_detail` (R/I). Element ids are positional
  per-walk — a moved view fails "take a fresh tree", never a guessed tap.
- **Snapshots** — `inspect_snapshot`, `inspect_timeline`, `inspect_diff`
  (named events), `inspect_clear_snapshots` (D/I dryRun). Gesture tools take
  `snapshot:none|pre|post|both` (default none). Launch sweeps unpinned;
  pins survive via bookmarks.
- **Bookmarks** — `bookmark_add/note/move/list/remove` (move/remove D/I
  dryRun; reference-not-value, capped; uninstall/data-wipe deletes the store).

## MCP recipes

- First instrumentation: list_apps → get_config → set_config → launch_app →
  tail_events (cursor loop).
- Hook loop: app_imports → find_symbols → set_*_hooks → relaunch.
- Tweak iteration: inspect_tweak → add_tweak (dryRun) → resync_tweaks.
- UI investigation: agentMode → uitree_read → tap/swipe (snapshot:both) →
  inspect_diff → bookmark_add.
- Container A/B: list_profiles → create/switch (refuses while running).
- Uninstall: uninstall_app dryRun → read preview → dryRun:false
  (+purgeData only deliberately).

## Redaction (pointer)

Default-redacted everywhere; raw capture needs explicit per-surface consent
(`inspectDisableRedaction`, `redactionKeys`). The consent UX is owned
separately — this file records the contract, not the flow. Secure tree text
arrives masked, secure pixels never exist, snapshots freeze redaction state,
keychain values are never readable.

## MCP errors (verbatim, self-correct)

`bundleID is required` · `app not installed: <bid>` · `app not running:
<bid> - launch it first (launch_app), then retry` · `Agent Mode is not
enabled for <bid>; turn it on in the app's Hacking settings, then relaunch
the app` · `take a fresh tree` (stale elementId) · `did you mean…` (unknown
set_config key) · `rate limited: <tool> … wait <N>s` · `inspect timed out
after 60s - guest pump silent since <t> - relaunch the app with Agent Mode
on` (or `no pump heartbeat` when the pump never beat). Liveness is one
shared definition (`InspectControl.isAppRunning`): workspace match OR fresh
heartbeat (<150 s) OR flowing writes (<120 s).

# MCP Guide — Operator Runbook

How to drive Ophanim headless over MCP. This is the **operator reference**:
every tool, its dry-run contract, and whether it applies live or needs a
relaunch. Orientation, glossary, and protocol rationale live in
`docs/CONTEXT.md`, `docs/ARCHITECTURE.md`, and `docs/INSPECT.md` — this file
does not repeat them.

Ground truth: the catalog is `MCPServer.toolDefinitions`
(`Ophanim/Core/MCP/MCPServer.swift:241`), routed via `ToolRouter.handlers`
(`Ophanim/Core/MCP/ToolRouter.swift:85-151`, 65 entries) plus the 18
inspect-routed tools in `InspectTools.inspectToolNames`
(`Ophanim/Core/MCP/Tools/Inspect/InspectTools.swift:740-748`) — 83 tools
total. Annotations ride on `tools/list`: `readOnlyTools`
(`MCPServer.swift:36-48`, 35 tools) and `destructiveTools`
(`MCPServer.swift:51-66`, 42 tools). `launch_app`, `tap_element`, `swipe`,
and `set_text` carry **neither** hint — mutating but unannotated; treat them
as live-effect tools (no dry run exists for the three gestures).

Conventions: **R** read-only · **D** destructive · **I** idempotent.
`bundleID` is required by every per-app tool
(`ToolRouter.requireBundleID`, `ToolRouter.swift:21-24`).

## Session rules (read first)

1. `list_apps` → bundle IDs. 2. `get_config` (or `get_hooks` for hook-only
   work) before any mutation. 3. Preview before executing (see dry-run
   contracts below — the two families differ).
4. Rate limit is 120 calls/min **per tool**; the refusal states the wait —
   wait it out, don't hammer (`MCPServer.swift:127-147`).
5. Results carry `structuredContent` mirrored as text JSON — read either
   (`MCPServer.swift:196-203`). Failures are `isError: true` with
   self-correcting messages, including unknown tool *names*
   (`MCPServer.swift:182-185`). Unknown *arguments* are rejected with a
   did-you-mean suggestion (`ToolRouter.rejectUnknownKeys`,
   `ToolRouter.swift:46-64`).

## Dry-run contracts (two families — do not mix them up)

| Family | Rule | Code |
|---|---|---|
| Most destructive tools (uninstall, tweaks, containers, sources, keymaps, injection strategy, galgal runtime, clear/reset) | `dryRun` **defaults true**: omitted = preview, pass `dryRun:false` to execute | `ToolRouter.isDryRun`, `ToolRouter.swift:43` |
| Hook/rule writers: `set_objc_hooks`, `set_swift_hooks`, `set_inline_hooks`, `set_rules`, `apply_preset` | **Omitted = write** (historical contract). Preview only with explicit `dryRun:true` | `HookTools.swift:5-9`, `RuleTools.swift:20-21`, `RuleTools.swift:42-43` |
| Pure setters / gestures: `set_config`, `tap_element`, `swipe`, `set_text` | **No dry run at all** — the call is the effect | catalog descriptions, `MCPServer.swift:484-553`; gesture handlers `InspectTools.swift:89-180` |

`set_config` has no preview: re-read with `get_config` after writing
(`ConfigTools.setConfig`, `ConfigTools.swift:11-17` returns the new projection).

## Live vs relaunch

| Takes effect live on a running app | Needs relaunch / next launch |
|---|---|
| Capture categories, rules, sinks, `bypassPinning` (config is watched — `set_config` description, `MCPServer.swift:484-488`) | Newly added hooks (`set_*_hooks` replace the stored arrays; engine reads them at boot — same note, `MCPServer.swift:484-488`) |
| `set_rules` ("Takes effect live on a running app", `MCPServer.swift:331-348`) | Injection strategy (`set_injection_strategy` rewrites load commands; "next launch applies" pattern, `ConfigTools.swift:24-64`) |
| Inline-hook gate `enableInlineHooks` ("live code patching", `MCPServer.swift:451-476`) | DYLD libraries ("Takes effect on next launch", `AppTools.swift:182-186`) |
| Turning Agent Mode OFF (stops serving within one poll) | Turning Agent Mode ON (boot latch — guest pump only boots at launch; see `docs/INSPECT.md`) |
| Dropped hook entries "reverted live on next config poll" (hook catalog text, `MCPServer.swift:418-426`) | `install_app` output (configure with `set_config`, then `launch_app`, `AppTools.swift:77`) |

## Tool catalog by domain

### Apps (lifecycle + binary patching)

| Tool | R/D | Purpose + key args |
|---|---|---|
| `list_apps` | R/I | Inventory: bundleID, name, version, `instrumentationEnabled`, `captureCategories`, live `running` flag (`AppTools.swift:18-31`) |
| `launch_app` | live effect, unannotated | Launches via the same path as the GUI library (PROHIBITED/MALICIOUS gates apply); bounded wait, bails if launch doesn't finish (`AppTools.swift:33-54`) |
| `install_app` | D | `ipaPath` (.ipa only, `~` expanded). Full pipeline — see "Install / sign flow" below. Fail-loud: timeout or validation failure throws, never reports a dead install as success (`AppTools.swift:56-81`) |
| `uninstall_app` | D/I, dryRun-default | Removes bundle + per-app config; container (logs) preserved unless `purgeData:true`. Preview and execute share one inventory (`AppTools.swift:83-92`) |
| `set_galgal_runtime` | D, dryRun-default | `installed` (required bool). Headless twin of the settings-window Galgal button; settle-polls and reports `verified` (`AppTools.swift:97-148`) |
| `set_dyld_libraries` | D, dryRun-default | `introspection` / `iosFrameworks` bools (at least one required). Re-signs; next launch applies (`AppTools.swift:153-190`) |
| `set_app_category` | D, dryRun-default | `category` (required, must be a valid `LSApplicationCategoryType` — error lists all valid values). Re-signs via `Shell.signApp` (`AppTools.swift:194-222`) |
| `prune_files` | D, dryRun-default | No args. Trashes per-app files orphaned by uninstalled apps (`AppTools.swift:226-234`) |

### Config (incl. keymaps, jailbreak, injection strategy)

| Tool | R/D | Purpose + key args |
|---|---|---|
| `get_config` | R/I | Full per-app projection: `instrumentation` (engine) vs `hosting` groups. Mirrors what `set_config` writes (`ConfigTools.swift:5-9`; shape in `MCPServer.swift:371-382`) |
| `set_config` | D, **no dry run** | Field-level patch; omitted fields unchanged. Unknown keys rejected with did-you-mean. Key fields: `enabled`, `categories` (network/keychain/crypto/device/privacy/filesystem/process/jailbreak), `sinks` (ndjson/text/console), `bypassPinning`, `enableInlineHooks`, `agentMode`, `inspectDisableRedaction`, `redactionKeys`, `bodyCapBytes` (1024–8388608), `jailbreakBypass`/`jailbreakBypasses` (`"all"`/`"none"`/ids), `chainGuard`, plus window/graphics/input hosting flags (`MCPServer.swift:484-553`; `ConfigTools.swift:11-17`) |
| `get_hooks` | R/I | Lightweight twin of `get_config` for hook polling: three hook arrays + inline gate, no hosting dump (`HookTools.swift:54-70`) |
| `list_jailbreak_detectors` | R/I | Bypassable detector SDK ids + labels; feed ids into `jailbreakBypasses` or pass `"all"` (`ConfigTools.swift:19-22`) |
| `set_injection_strategy` | D, dryRun-default | `strategy`: `embedded` \| `sibling`. Persists + settles load commands; reports `verified:true` only when measured, else a note (`ConfigTools.swift:24-64`) |
| `get_keymap` | R/I | Read-only keymap JSON **by design** (`ConfigTools.swift:66-75`) |
| `set_keymap` | D, dryRun-default | `name` + full `keymap` object (+`allowBundleMismatch`, default false). Validated full-blob replace: name gate, enforced bundle binding, backup, atomic replace (`ConfigTools.swift:80-122`) |
| `list_keymaps` | R/I | Keymap files with sizes + default marker (`ConfigTools.swift:144-161`) |
| `rename_keymap` / `delete_keymap` | D, dryRun-default | `name` + `newName` / `name`. Delete refuses the default keymap like the GUI (`ConfigTools.swift:164-201`) |
| `reset_settings` | D, dryRun-default | Reset to defaults; bundle binding preserved (`ConfigTools.swift:127-140`) |

### Hooks / rules (interception authoring)

| Tool | R/D | Purpose + key args |
|---|---|---|
| `list_presets` | R/I | `block-trackers`, `fake-idfv`, `fake-idfa`, `block-host {host}`, `fake-device-id {value}` (`RuleTools.swift:6-12`) |
| `apply_preset` | D, **omitted = apply** | `preset` (required). Merges by id — existing ids skipped, reported as `skipped`; `dryRun:true` previews wouldAdd/skipped (`RuleTools.swift:14-36`) |
| `set_rules` | D, **omitted = write** | `rules` (required, full replace). Script rules take effect live. `dryRun:true` previews the count (`RuleTools.swift:38-47`) |
| `validate_rule_script` | R/I | `script` (required). Parses only, never executes (wrapped in an uncalled function). Top-level `return` fails validation — correct, because the contract is ctx mutation (`RuleTools.swift:49-69`) |
| `set_objc_hooks` | D, **omitted = write** | `hooks` (required, full replace). `{className, selector, args 0-3 (default 1), classMethod, category, api?, imageGlob?}`. Void methods only; `objc_msgSend`-dispatched calls only — direct Swift calls and pure-Swift methods unreachable (`HookTools.swift:11-21`; `MCPServer.swift:410-427`; shape `OPConfig.swift:72-97`) |
| `set_swift_hooks` | D, **omitted = write** | `{className (_TtC… form from `find_symbols`), method (substring of mangled symbol), category, api?, imageGlob?}`. Vtable-dispatched methods only; `-O` devirtualization bypasses the vtable — use inline hooks instead. Failures aggregate in `ophanim.swiftHook.installSummary` events (`HookTools.swift:23-33`; `MCPServer.swift:429-449`; shape `OPConfig.swift:102-122`) |
| `set_inline_hooks` | D, **omitted = write** | `{api, category, module?, symbol?, address?, offset?, signature?, followThunk?, captureReturn?, renderArgs?, renderReturn?}`. arm64 only; gated on `enableInlineHooks=true` (reports `gateOn`; warns when off). Locate priority: address → symbol → module+offset → module+signature (`HookTools.swift:35-48`; `MCPServer.swift:451-476`; shape `OPConfig.swift:170-208`) |

Rule match/action shapes: `match` = AND of `categories?`, `apiGlob?`,
`hostGlob?`, `urlGlob?`, `pathGlob?`, `argContains?`
(`OPConfig.swift:23-32`); `action.kind` ∈
observe/modifyArgs/replaceReturn/block/delay/fault/script with static payloads
(`replacementBodyBase64`, `replacementHeaders`, `replacementStatus`,
`cannedReturnValue`, `cannedArgs` for inline x0–x7 rewrites,
`delayMilliseconds`, `faultErrorCode`) (`OPConfig.swift:36-52`). First
matching rule wins; no match = observe (`OPInterceptor.swift:84-89`). The
`ctx` script contract is documented under "Hook/rule authoring" below.

### Tweaks

| Tool | R/D | Purpose + key args |
|---|---|---|
| `list_tweaks` | R/I | `recursive` bool. Store entries (dylib/framework/folder, enabled state) (`TweakTools.swift:7-13`) |
| `inspect_tweak` | R/I | `path` (required; note: catalog marks `bundleID` required, handler reads `path` — pass both). Loadability + Mach-O facts. **Run BEFORE add** (`TweakTools.swift:15-19`; `MCPServer.swift:765-774`) |
| `add_tweak` | D, dryRun-default | `path` (required) + `replace` bool. Gate: un-loadable slices refused **before** copying. Name clash without `replace:true` refused (`TweakTools.swift:21-49`) |
| `move_tweak` | D, dryRun-default | `from`/`to` (required). Destination clash refused (`TweakTools.swift:51-74`) |
| `remove_tweak` | D, dryRun-default | `name` (required) (`TweakTools.swift:76-91`) |
| `set_tweak_enabled` | D, dryRun-default | `name` + `enabled` bool (required). `.disabled`-suffix convention; accepts the display name with or without the suffix (`TweakTools.swift:93-116`) |
| `tweak_folder` | D, dryRun-default | `action`: create/rename/remove + `name` (+`newName` for rename) (`TweakTools.swift:118-150`) |
| `resync_tweaks` | D, **no dryRun gate** | No args beyond bundleID. Re-syncs store into the app; idempotent repair after hand edits (`TweakTools.swift:152-162`) |

Add/move/remove/enable re-sync user dylibs into the executable after the
file op (`TweakTools.swift:46`, `72`, `89`, `113-114`).

### Containers (logs, profiles, data)

| Tool | R/D | Purpose + key args |
|---|---|---|
| `get_log_path` | R/I | Authoritative log dirs + ndjson files with sizes (`ContainerTools.swift:6-21`) |
| `clear_logs` | D/I, dryRun-default | Byte-counted log delete (`ContainerTools.swift:23-43`) |
| `container_info` | R/I | Resolved container report — never composed paths (`ContainerTools.swift:45-48`) |
| `list_profiles` | R/I | Profiles + active name + live-exists check (`ContainerTools.swift:50-59`) |
| `create_profile` | D, dryRun-default | `name` (required). Snapshots the live container (`ContainerTools.swift:61-72`) |
| `switch_profile` | D, dryRun-default | `name` (required). Refuses while the app runs (`OphanimError.containerRunning` → "Quit the app before changing its container", `ContainerProfiles.swift:96-98`, `OphanimError.swift:42-43`); dry run reports `wouldRefuse` (`ContainerTools.swift:74-86`) |
| `remove_profile` | D, dryRun-default | `name` (required). Removing the **active** profile is refused (`ContainerProfiles.swift:20`, `125-127`) |
| `clear_container` | D/I, dryRun-default | `scope`: caches/data/keychain/preferences (required). `data` scope also wipes the snapshot timeline + bookmarks (marks would point at a UI that no longer exists); other scopes stay surgical (`ContainerTools.swift:99-180`) |
| `backup_container` | D, dryRun-default | `destPath` (required). `ditto` zip; reports `wouldOverwrite` on preview (`ContainerTools.swift:182-201`) |
| `restore_container` | D, dryRun-default | `archivePath` (required). Refuses while running; replaces the live tree via `ditto` (`ContainerTools.swift:203-225`) |

### Sources (AltStore feeds)

| Tool | R/D | Purpose + key args |
|---|---|---|
| `list_sources` | R/I | Feeds with app counts, loading/error state (`SourceTools.swift:7-22`) |
| `search_source_apps` | R/I | `query` (required): substring over name/bundleID/developer, bundleID-merged (`SourceTools.swift:197-220`) |
| `add_source` / `remove_source` | D, dryRun-default | `url` (required). Remove matches by full URL **or host**; same matcher for refresh/rename/edit (`SourceTools.swift:24-53`, `83-88`) |
| `refresh_sources` | R (no dryRun gate) | `url` optional — one feed or all. Cache sync, no data loss (`SourceTools.swift:92-115`) |
| `rename_source` | D, dryRun-default | `url` + `name` (required) (`SourceTools.swift:118-129`) |
| `edit_source_url` | D, dryRun-default | `url` + `newUrl` (required). Cache follows, old cache purged (`SourceTools.swift:133-154`) |
| `reset_sources` | D, dryRun-default | No args. Drops every custom source + caches + resume data (`SourceTools.swift:158-165`) |
| `install_source_app` | D, dryRun-default | `bundleID` + optional `version` pin. Dry run reports the version/bytes that would install; execute waits to idle (bounded) and fails stated on failure/paused (`SourceTools.swift:55-78`) |
| `source_transfer` | D, dryRun-default | `action`: pause/resume/cancel (required) + optional `version` for resume (`SourceTools.swift:171-192`) |

### Events / recon

| Tool | R/D | Purpose + key args |
|---|---|---|
| `query_events` | R/I | `category?`, `search?` (case-insensitive over api/summary/fields), `limit` (default 200, newest kept) (`EventTools.swift:5-15`) |
| `tail_events` | R/I | Live poll: pass back `cursor` as `since` (ms epoch; `since:0` = latest batch, not history). `limit` default 100; `waitMs` long-poll up to 30000 ms (default 0 = single poll). Response carries `cursor`, `waitedMs` (`EventTools.swift:17-44`) |
| `subscribe_events` | live effect | Push `notifications/events/added` (cursor+count) on stdout; bodies via `tail_events`. **Stdio children only** — refuses over HTTP (`EventTools.swift:46-55`) |

Backtraces are ObjC-layer only by architecture, not by omission: ring-drained
(interpose/socket/TLS) events materialize on the consumer thread, where the
stack would be wrong, so only synchronous swizzle events carry
`captureBacktraces` stacks (`OPAgent.swift` event path). Use the network
caller-attribution flag (`captureNetworkCallers`, default off: dladdr cost)
for the hot-path equivalent.
| `unsubscribe_events` | live effect | `bundleID` optional — one feed or all. Reports `threadParked` (`EventTools.swift:57-63`) |
| `export_curl` | R/I | Newest recorded request matching `url?`/`host?`/`since?` rendered as replay-grade curl (method + url + `req.*` headers, text body to 4096 chars; binary bodies noted, never dumped) (`EventTools.swift:65-109`) |
| `analyze_app` | R/I | Behavior/privacy rollup from events + `crash` section: previous run's explanation (`last-crash.json`) or explicit no-artifact statement (`ReconTools.swift:5-8`) |
| `app_imports` | R/I | Dynamically-imported TLS/crypto/keychain/process symbols — the DYLD_INTERPOSE surface, incl. for statically-linked apps (`ReconTools.swift:10-15`) |
| `find_symbols` | R/I | `keyword` (required). Keyword allowlist (`A-Za-z0-9_.-:`) — injection-safe by construction (`ReconTools.swift:17-26`) |
| `list_libraries` | R/I | `otool -L` parse, same as the Recon view (`ReconTools.swift:37-54`) |
| `scan_signature` | R/I | `pattern` (required, `"1F 20 ?? D5"` form). Capped at 500 hits (`ReconTools.swift:56-74`) |
| `list_classes` | R/I | `filter?`, `limit` (default 200, cap 2000). Live-first: runtime classes when Agent Mode runs, else static strings (`ReconTools.swift:28-35`; `InspectTools.swift:752-759`) |

### Inspect / snapshots / bookmarks

Full protocol in `docs/INSPECT.md`. Tool notes: `uitree_read` and
`screenshot` are R/I; `tap_element` (`elementId` preferred, or x+y in 0...1),
`swipe` (`x1/y1/x2/y2` + `steps` 1...20, default 8), `set_text`
(`elementId` + `text`) are live-effect, no dry run
(`InspectTools.swift:89-180`). `inspect_pick` resolves x/y to an elementId
(hitTest-independent; disabled views resolve) (`InspectTools.swift:115-133`).
`inspect_classes` (filter-first, limit 1...2000), `inspect_element`
(subtree + superclasses + VC), `inspect_class_detail` (methods/ivars —
copy/free stays in C) are R/I (`InspectTools.swift:182-234`).
`inspect_snapshot` pins tree + optional JPEG (`withScreenshot`);
`inspect_timeline` lists metadata + latest-pair summary;
`inspect_diff` needs same-mode/same-filter/same-root/same-caps/**same-scene**
pairs, marks budget-cut or redaction-mismatched pairs `partial`;
`inspect_clear_snapshots` is D/I dryRun-default
(`InspectTools.swift:236-349`). Gestures take `snapshot: none|pre|post|both`
(default none — each leg costs a full tree transaction;
`InspectService.swift:137-155`).

`uitree_read` summaries carry flat `nodes[]` (id/class/role/text/label/
enabled, buttons + text inputs + labeled nodes, capped 100, zero nesting):
the discovery list for `tap_element`/`set_text` by id when the tree text
block is unavailable — proven live driving a full chat turn (read nodes,
tap field, `set_text`, tap Send) with no coordinates.

Framework coverage for text entry (`set_text` writes `UITextField`/
`UITextView` directly — no tapping, no keyboard): UIKit and SwiftUI
(hosts the same two classes) fully covered; **React Native covered** —
its inputs are UIKit-level `RCTUITextField`/`RCTUITextView`
(first-party `react-native` source), caught by the same classifier;
**Flutter not covered** — it renders into a single engine view with no
`UIViews` per widget, so there is nothing to write to (tap/swipe/
screenshot/capture still work; engine-level text injection is out of
scope for the policy model).
(default none — each leg costs a full tree transaction;
`InspectService.swift:137-155`). Bookmarks: `bookmark_add` (class/symbol by
name; element needs a pinned snapshot or one is captured fresh; bookmark and
pin caps enforced), `bookmark_note`, `bookmark_move` (dryRun-default, unknown
ids fail before mutation, groups auto-create), `bookmark_list` (staleness
hints, `checkFresh` re-reads live), `bookmark_remove` (dryRun-default;
groups free members, snapshots unpin) (`InspectTools.swift:351-603`).

## Hook/rule authoring

**Rule shape.** `{id, enabled, note?, match, action}` (`OPConfig.swift:55-67`).
Match fields AND together (`OPConfig.swift:23-32`); first matching enabled
rule wins (`OPInterceptor.swift:84-89`).

**`ctx` script contract** (`OPInterceptor.swift:151-212`, bridge built at
`OPInterceptor.swift:154-167`):

| Script writes | Effect |
|---|---|
| `ctx.block = true` | Block the call (checked first, `OPInterceptor.swift:172-174`) |
| `ctx.returnValue = '…'` | Stringified replacement return (`OPInterceptor.swift:184-186`) |
| `ctx.replacementBody = '<base64>'` | Replacement bytes (must be valid base64 or ignored, `OPInterceptor.swift:177-180`) |
| `ctx.replacementStatus = <int>` | HTTP status override (`OPInterceptor.swift:181-183`) |
| `ctx.x0` … `ctx.x7` | Inline register edits. Arg-only scripts resolve to `.argsModified` (original runs with edited regs), **not** `.returnReplaced` (`OPInterceptor.swift:187-200`) |
| `ctx.state.*` | Per-rule persistent strings. Capped: 32 keys, 256 chars/value, keep-first; resets on config reload (`OPInterceptor.swift:62-68`, `201-210`) |

| Script reads | Notes |
|---|---|
| `ctx.method`, `ctx.statusCode` | `statusCode` is -1 when absent (`OPInterceptor.swift:160-161`) |
| `ctx.category/api/host/url/path/fields`, `requestBodyBase64/responseBodyBase64` | Request/response bodies arrive base64 (`OPInterceptor.swift:154-167`) |

Static (non-script) equivalents: `modifyArgs` rewrites via `cannedArgs`
(`{"x0":"0x…"}`) and/or first-body-bytes; `replaceReturn` via
`replacementBodyBase64`/`replacementStatus`/`cannedReturnValue`
(`OPInterceptor.swift:120-132`). `renderArgs`/`renderReturn` on inline hooks
(`nsdata|nsstring|objcDesc|cString`) deref registers safely with hex fallback
(`OPConfig.swift:155-163`; `MCPServer.swift:460-466`).

**Presets.** `block-trackers` = one script rule (`op-block-trackers`,
network-only, lowercased host substring match — breaks deep-link resolution +
in-app ads while active); `fake-idfv`/`fake-idfa` = fixed-UUID script rules
on `UIDevice.identifierForVendor` / `ASIdentifierManager.advertisingIdentifier`;
templated `block-host` (`parameters.host`, metacharacters rejected) and
`fake-device-id` (`parameters.value`, quote-stripped) (`RuleTools.swift:72-110`).

**Authoring flow.** `validate_rule_script` → `set_rules` (full replace;
`dryRun:true` previews count) → live on running app for rules; new hooks need
relaunch. `get_hooks` for cheap hook polling instead of the full `get_config`
dump (`HookTools.swift:50-53`).

## Install / sign flow (incl. skip-guard, fail-loud)

`install_app` runs the GUI importer headless with Galgal injection forced
(`injectGalgal: true`, no modal — `AppTools.swift:64-71`; GUI prompt logic in
`Installer.swift:50-66`). Pipeline (`Installer.swift:71-120`):

1. Unzip → save entitlements → resolve valid Mach-Os.
2. Encrypted binaries refused stated (`OphanimError.appEncrypted`,
   `Installer.swift:87-89`).
3. `convertMacho` + `signMacho` per binary (non-export path,
   `Installer.swift:91-95`); Galgal injected (`Installer.swift:99-101`);
   permissions `0o755`, mobileprovision removed, minimum-version asserted.
4. Boundary check: the installed bundle must validate as a runnable Catalyst
   app via `IPAValidate.installedApp` — a non-runnable bundle fails here,
   not as "Installed" followed by a dead run (`AppTools.swift:75-76`).
5. Install waits on a bounded semaphore; timeout or nil result throws
   (`AppTools.swift:72-73`). `Shell.run` throws on any nonzero exit
   (`Shell.swift:36-42`) — installs fail loud, never half-sealed.

**Signing + the Settings.bundle skip-guard** (`Shell.swift:90-158`):
`signApp`/`signAppWith` sign nested code leaf-first (never `--deep`), then
the top bundle. `signNestedCode` walks top-level `framework/bundle/dylib/app/
appex` items plus `PlugIns/Frameworks/Helpers`. Resource-only bundles without
`Info.plist` (e.g. `Settings.bundle`) are **skipped** — codesign rejects them
with "bundle format unrecognized", which used to abort the whole seal and
ship a dead app; the top-level seal covers their resources
(`Shell.swift:111-114`, `120-123`). `isSignableCode`: directories need
`Info.plist` (or `Contents/Info.plist`); files need Mach-O magic
(`Shell.swift:141-158`).

## Recipes

- First instrumentation: `list_apps` → `get_config` → `set_config` →
  `launch_app` → `tail_events` (cursor loop; or `subscribe_events` +
  `tail_events` on stdio).
- Hook loop: `app_imports` → `find_symbols` → `set_*_hooks` → relaunch →
  `query_events` to confirm.
- Zero-code trace (frida-trace shape, no engine work): `find_symbols` for the
  keyword → `list_classes` (live) → `inspect_class_detail` on each class hit
  → hand-write `set_objc_hooks` entries (className + selector) → validate
  with `set_objc_hooks` `dryRun:true` → apply → `query_events` for the
  `ophanim.objcHook.install` lines + `installSummary`. Never cross-product
  static selectors × classes (pairings must come from the live inventory);
  revert with `set_objc_hooks` minus the entries (P5 reverts on reload).
- Rule loop: `validate_rule_script` → `set_rules` (`dryRun:true` first) →
  live, no relaunch for rules.
- Tweak iteration: `inspect_tweak` → `add_tweak` (dryRun preview) →
  `resync_tweaks` after hand edits.
- UI investigation: `agentMode` on + relaunch → `uitree_read` →
  `tap`/`swipe` (`snapshot:both`) → `inspect_diff` → `bookmark_add`.
- Container A/B: `list_profiles` → `create`/`switch` (quit the app first) →
  `clear_container` as needed.

## Proven loops (device-tested)

- Chat turn, no coordinates: fresh `uitree_read` → `find_element` (text) →
  tap field (focus first on custom inputs — bare `set_text` lands invisibly
  on delegate-gated fields) → `set_text` same id → tap Send id → screenshot
  verify. Stale ids fail stated by design; re-read and retry.
- Gated action: `find_element` → `tap_and_read` shows the resulting UI
  (e.g. Follow → phone-verification gate) in one round trip.
- Full app read: `launch_status` (workspace-blind but pump-live happens —
  trust `agentLive`) → `container_info` (seal/entitlements/prefs path) →
  `container_read` the prefs plist (use the ABSOLUTE path from
  `container_info`; relative paths resolve against the wrong root) →
  `keychain_items` → `sqlite_tables`/`sqlite_rows` on the app's databases.
- Missing tooling found live: no `terminate_app` — restarting for
  agentMode/config changes currently needs an external kill; `launch_app`
  on a running app only activates.
- Replay: `export_curl` → paste in Terminal, compare statuses.
- Uninstall: `uninstall_app` dryRun → read preview → `dryRun:false`
  (+`purgeData` only deliberately).

## Errors (verbatim, self-correct)

`bundleID is required` · `app not installed: <bid>` · `install failed - see
the Ophanim log for details` (fail-loud, `AppTools.swift:73`) · `Agent Mode
is not enabled for <bid>; turn it on in the app's Hacking settings, then
relaunch the app` · `take a fresh tree` (stale elementId) · unknown-arg
`did you mean…` (`ToolRouter.swift:46-64`) · `rate limited: <tool> … wait
<N>s` · `snapshot '<id>' not found` / `pin cap reached` / `bookmark cap
reached` (`InspectTools.swift:379-389`, `357-358`) · `inspect timed out
after 60s - guest pump silent since <t> - relaunch the app with Agent Mode
on` (or `no pump heartbeat` when the pump never beat,
`InspectService.swift:124-131`) · `Quit the app before changing its
container.` (container ops while running, `OphanimError.swift:42-43`).

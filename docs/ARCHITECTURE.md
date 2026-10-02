# Architecture

Three images, one pipeline: hooks → ring → policy → sinks.

- **Ophanim.app** (`Ophanim/`): host macOS app. `App/` composition only;
  `Features/` per user goal (AppLibrary, AppSettings, KeyCover, Keymap,
  Instrumentation, Recon, Rules, Install, Onboarding); `Core/` shared kernel
  (Model value types, Services I/O, MCP router/tools/transports, Support
  process/plist/extensions, ViewModel stores); `DesignSystem/` theme/styles.
  Rule: features never import each other; shared code sinks to `Core/`.
- **Galgal** (`Galgal/`, upstream runtime): embedded loader + plugin.
  Owns Keychain emulation and FS path rewrite. Upstream-owned — do not
  reorganize internals here.
- **OphanimCore** (`OphanimCore/`): hook engine compiled twice.
  `ring/` lock-free SPSC (`op_ring_emit` allocation-free, any-context);
  `hooks/` Tier-1 interpose + Tier-2.5 Swift vtable + Tier-3 inline engine
  (arm64 only; arm64e refused at compile time `OPInline.c:17-21` and runtime
  `OPInline.c:229-232,317`); `bridge/` C→Swift thin adapters with re-entrancy
  guard; `policy/` match→decision (observe/block/delay/fault/modify/replace/script);
  `loader/` agent singleton + sinks; `compat/` single macro + constants table
  (CI-pinned: `build.yml` R7 gate rejects local `DYLD_INTERPOSE` defines).
  Dual-target split: `OPConfig` + `OPEvent` compile into host AND guest;
  `OPInterceptor` is guest-only (`OPConfig.swift:138-139`, local glob copy).
- **Embedded vs sibling**: embedded = Galgal.framework (umbrella header
  bridge); sibling = OphanimAgent.dylib (`-import-objc-header OPRing.h`,
  `-D OPHANIM_SIBLING`). Keychain stays Galgal-owned. No double interpose.
- Executable spec: `scripts/test/integration-test.sh` asserts the capability
  matrix; unit: `scripts/test/reloctest.c` (relocator).

## Module layout (verified 2026-10-01 — list what exists, nothing invented)

- `Ophanim/App/` — composition only: `OphanimApp.swift` (entry; `--mcp`
  dispatch to stdio/HTTP), `MainView.swift`, `MenuBarView.swift`.
- `Ophanim/Core/` — shared kernel: `MCP/` (`MCPServer.swift`, `ToolRouter.swift`,
  `MCPTimeouts.swift`, `InspectGate.swift`, `Tools/` 9 domain dirs / 11 files
  (`Apps`, `Config`, `Containers`, `Events`, `Hooks/{Hook,Rule}Tools`,
  `Inspect`, `Recon`, `Sources`, `Tweaks`), `Services/` ×6, `Transports/` ×3:
  `StdioTransport`, `HTTPTransport`,
  `EventNotifier`); `Model/` (value types incl. `HostedApp*`, `AppSettings`
  (LLDB flags live on `AppSettingsData`, `AppSettings.swift:60-63`),
  `KeymapData`); `Services/` (I/O: `LogStore`, `SnapshotStore`,
  `BookmarkStore`, `Galgal`,
  `OPAppLiveness`, `OPCrashCorrelator`, …); `Support/` (process/plist/shell/
  extensions — install seal in `Shell.signNestedCode`, `Shell.swift:115-139`);
  `ViewModel/` (stores). `Rules/` (`default.yaml`) sits beside.
- `Ophanim/Features/` — one dir per user goal: AppLibrary, AppSettings,
  Install, KeyCover, Keymap, Onboarding, Recon, Rules, Sources. Rule: features
  never import each other.
- `Ophanim/DesignSystem/` — theme/styles (`Controls.swift`, `ToastView.swift`).
- `OphanimCore/` — `ring/` (`OPRing.h/.m`, `OPRingBridge.swift`),
  `hooks/` (`capture/` Network/Filesystem/Device, `boundary/` Configurable/Swift,
  `interpose/` Crypto/Pinning/Process/Socket/TLS, `inline/` Inline, plus the engine
  trio `OPInline.c/.h` + `OPInlineAsm.s` and sibling-only `OPHooksFSRaw.m` at
  `hooks/` root), `bridge/` (CallerAttribution/Crypto/FS/Keychain/Observe/
  Process/Reentry/Socket/TLS), `policy/` (`OPConfig`, `OPInterceptor`, `OPEvent`),
  `loader/` (`OPAgent`, `OPAgentDylib.m`, `OPBootstrap`, `OPLogSink`),
  `compat/` (`OPInterpose.h`, `OPConstants.h`), `crash/` (trap/record/writer/guard).
- `Galgal/Galgal/` — upstream runtime target: `GalgalLoader.m`, `Inspect/`
  (protocol + pump, compiles into guest+host), `Controls/`, `Editor/`,
  `Keymap/`, … Upstream-owned, do not reorganize.

## Hook engine P1–P6 (guest behavior; MCP surface in `CONTEXT.md`)

- **P1 script state** — JS rules see `ctx` with reads `ctx.method`,
  `ctx.statusCode` (-1 when absent) plus string fields, and may set
  `ctx.block`, `ctx.returnValue`, `ctx.replacementBody/Status`,
  per-register `ctx.x0`…`ctx.x7`, or persistent `ctx.state.*` (per-rule
  string dict, 32 keys × 256 chars, reset on config reload —
  `OPInterceptor.swift:147-210`). Arg-only scripts resolve to `.argsModified`
  (run the original with edited regs), not `.returnReplaced`
  (`OPInterceptor.swift:187-199`).
- **P2 inline args** — on the RESUME path explicit `cannedArgs` rewrites land in
  x0–x7; otherwise the first up-to-8 `replacementBody` bytes load into x0
  (documented modifyArgs contract; malformed keys ignored fail-open —
  `OPHooksInline.swift:266-278`). REPLACE returns with x0 set, skipping the
  original (`OPHooksInline.swift:258-295`).
- **P3 dyld retry** — `op_image_retry_arm()` at boot (`OPBootstrap.swift:62-64`,
  impl `OPInline.c:447-454`, contract `OPInline.h:61-68`); the config poll
  drains it via `op_image_retry_pending()` and re-runs the idempotent user-hook
  install on main so late-loaded images resolve (`OPAgent.swift:166-174`).
- **P4 install accounting** — inline installs aggregate failures into one
  `ophanim.inlineHook.installSummary` event (`OPHooksInline.swift:126`);
  hooks whose class resolves to the wrong image record `image-mismatch`
  (`OPHooksConfigurable.swift:78`, `OPHooksSwift.swift:127`).
- **P5 bounded revert** — reload removes first: `installUserHooks` runs
  `removeNotIn` on all three tiers before installing (`OPBootstrap.swift:89-99`).
  ObjC restores the saved IMP (`OPHooksConfigurable.swift:29-48`), Swift writes
  back the saved vtable slot (`OPHooksSwift.swift:29-42`), inline restores
  original bytes and quarantines-not-frees the page (`OPHooksInline.swift:60-65`).
  No thread suspension anywhere.
- **P6 image scoping** — `OPObjCHook`/`OPSwiftHook.imageGlob` restricts hooking
  to classes whose dyld image matches (`OPConfig.swift:79,107`);
  `OPImageScope.matches` is nil/empty-means-all (`OPConfig.swift:133-136`).
  Install pipeline note: `Shell.signNestedCode` skips resource-only bundles
  without Info.plist (e.g. Settings.bundle) instead of aborting the seal
  (`Shell.swift:111-139`); `HostedApp.sign()` throws so a broken seal fails the
  install loudly (`HostedApp+Files.swift:40-52`).

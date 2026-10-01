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
  `hooks/` Tier-1 interpose + Tier-3 inline engine (arm64 only, refuses arm64e);
  `bridge/` C→Swift thin adapters with re-entrancy guard; `policy/`
  match→decision (observe/block/delay/fault/modify/replace/script);
  `loader/` agent singleton + sinks; `compat/` single macro + constants table.
- **Embedded vs sibling**: embedded = Galgal.framework (umbrella header
  bridge); sibling = OphanimAgent.dylib (`-import-objc-header OPRing.h`,
  `-D OPHANIM_SIBLING`). Keychain stays Galgal-owned. No double interpose.
- Executable spec: `scripts/test/integration-test.sh` asserts the capability
  matrix; unit: `scripts/test/reloctest.c` (relocator).

## Module layout (verified 2026-10-01 — list what exists, nothing invented)

- `Ophanim/App/` — composition only: `OphanimApp.swift` (entry; `--mcp`
  dispatch to stdio/HTTP), `MainView.swift`, `MenuBarView.swift`.
- `Ophanim/Core/` — shared kernel: `MCP/` (`MCPServer.swift`, `ToolRouter.swift`,
  `MCPTimeouts.swift`, `InspectGate.swift`, `Tools/` ×10 family files,
  `Services/` ×6, `Transports/` ×3: `StdioTransport`, `HTTPTransport`,
  `EventNotifier`); `Model/` (value types incl. `HostedApp*`, `AppSettings`,
  `KeymapData`); `Services/` (I/O: `LogStore`, `SnapshotStore`,
  `BookmarkStore`, `Galgal`,
  `OPAppLiveness`, `OPCrashCorrelator`, …); `Support/` (process/plist/shell/
  extensions); `ViewModel/` (stores). `Rules/` (`default.yaml`) sits beside.
- `Ophanim/Features/` — one dir per user goal: AppLibrary, AppSettings,
  Install, KeyCover, Keymap, Onboarding, Recon, Rules, Sources. Rule: features
  never import each other.
- `Ophanim/DesignSystem/` — theme/styles (`Controls.swift`, `ToastView.swift`).
- `OphanimCore/` — `ring/` (SPSC), `hooks/` (Tier-1 interpose + Tier-2.5 Swift
  vtable + Tier-3 inline), `bridge/` (C→Swift adapters), `policy/`
  (match→decision), `loader/` (agent singleton + sinks), `compat/` (macro +
  constants), `crash/` (trap/record/writer/guard).
- `Galgal/Galgal/` — upstream runtime target: `GalgalLoader.m`, `Inspect/`
  (protocol + pump, compiles into guest+host), `Controls/`, `Editor/`,
  `Keymap/`, … Upstream-owned, do not reorganize.

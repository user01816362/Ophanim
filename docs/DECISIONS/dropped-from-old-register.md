# OLD decision register — dispositions

Every entry in OLD `docs/DECISIONS.md` lands in exactly one bucket. Grep-provable;
re-check the cited path before reopening.

## Shipped (counterpart exists)

- MD-1 floor 26 → the floor; `Ophanim.xcodeproj` deployment target.
- MD-8/MD-9 fx + brand → deleted; no `Theme.*`/effect views in `Ophanim/`.
- MD-10 transport → satisfied as opt-in: HTTP only with `--port`
  (`Ophanim/App/OphanimApp.swift`), never default-on; stdio is primary.
  Bearer token added (ADR-0009): required for write tools on non-loopback
  binds, minted + persisted + printed on first use.
- MD-13 `server/discover` → shipped (`Ophanim/Core/MCP/MCPServer.swift`).
- MD-14 acquisition surface → `Features/Sources/` + `SourceTools.swift`.
- MD-11 versioning → `build.yml` tags + publishes on green main.
- MD-2 TN2206 convert → `Macho.convertMacho` path frozen (install pipeline).
- MD-3 notarize-no, MD-4 min-OS-no → current posture, no change proposed.

## Dropped (deliberate, do not re-litigate without new evidence)

- MD-6 broken release assets → OLD-repo history; fresh repo, fresh tags.
- MD-7 instance identity → deferred; bundle ID remains the identity key.
- MD-12 "no SwiftPM" → superseded: the build uses 5 SPM packages
  (`project.pbxproj` `XCRemoteSwiftPackageReference`).
- NEW-1 licence → owner decision, not a code task.
- NEW-2 CoreUI removal → verify by grep if revived; no live reference kept.
- Spoof snapshot / Darwin map / oemID / Carthage / `--deep` / TrollStore /
  iTunes / cydia markers → never-port list (install-proven scope).

## Carried (open, device or owner needed)

- MD-5 Debug configuration → `Ophanim.xcscheme` still names a `Debug` the
  project does not define; cheapest route to a test target when wanted.
- Checklist items 1–2 (install path, launch-and-look) → manual-only, stay in
  the release process, not in code.
- Checklist items 3–5 (install/launch/capture/MCP drive + crash check) →
  automated in `scripts/test/integration-test.sh`.

## Verdicts (code-verified 2026-10-01; do not reopen without new evidence)

- HostWindow → deduped, no reopen. Zero `HostWindow` matches in the tree
  (grep, 2026-10-01). Window fan-out lives in `SettingsWindowManager`
  (`Ophanim/Features/Rules/SettingsWindowManager.swift:10-11`) plus
  `AppSettingsWindowManager`
  (`Ophanim/Features/AppSettings/AppSettingsWindow.swift:98-99`), with live
  call sites (`AppLibraryView.swift:92`, `HostedAppView.swift:39`,
  `LogViewerView.swift:22`, `ReconView.swift:25`, `AppSourcesView.swift:22`).
- OPSwizzle → inlined/upstream, no separate layer to revive. Zero `OPSwizzle`
  matches in the tree. ObjC swizzle helpers
  (`swizzleInstanceMethod`/`swizzleExchangeMethod`/`swizzleClassMethod`) plus
  the `PTSwizzleLoader` +load applier live upstream in Galgal
  (`Galgal/Galgal/Controls/PTFakeTouch/NSObject+Swizzle.m:25-64,248-356`),
  which this repo does not reorganize (see `ARCHITECTURE.md`).
- Keymap writes → SHIPPED as `set_keymap` (catalog
  `Ophanim/Core/MCP/MCPServer.swift:1040`, route
  `ToolRouter.swift:150`, validated writer `ConfigTools.swift:80-122`:
  name gate, enforced bundle binding, backup, atomic replace, dryRun default).
- Streaming → SHIPPED as `tail_events waitMs` (catalog
  `MCPServer.swift:265`, long-poll cap 30000 `EventTools.swift:21-32`) plus
  `subscribe_events`/`unsubscribe_events` (catalog `MCPServer.swift:280-292`,
  handlers `EventTools.swift:49-63`, emitter `Transports/EventNotifier.swift`);
  design in ADR-0010.

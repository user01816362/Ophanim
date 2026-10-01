# OLD decision register — dispositions

Every entry in OLD `docs/DECISIONS.md` lands in exactly one bucket. Grep-provable;
re-check the cited path before reopening.

## Shipped (counterpart exists)

- MD-1 floor 26 → the floor; `Ophanim.xcodeproj` deployment target.
- MD-8/MD-9 fx + brand → deleted; no `Theme.*`/effect views in `Ophanim/`.
- MD-10 transport → satisfied as opt-in: HTTP only with `--port`
  (`Ophanim/App/OphanimApp.swift`), never default-on; stdio is primary.
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

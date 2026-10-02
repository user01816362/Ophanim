# Debugging

Red to green loop for this repo. State your conclusion explicitly; cite `file:line` for every claim or label it `[unverified]`.

## Red to green loop

1. State the conclusion first: what failed, in one sentence, with the failing command and output.
2. Run the gates CI runs, in order (`AGENTS.md:22-26`): DRY grep gates, relocator self-test, `swiftc -parse` on touched files plus a typecheck diff against pristine `HEAD`, then `./build-ophanim.sh Release` plus bundle checks.
3. Log failed greps, not just passing ones: record the exact pattern that returned empty, so the next reader knows the negative was checked.

## Greatest hits

- `Sendable` in guest-shared files. `OPCrashRecord.swift:12-14` deliberately carries no `Sendable` conformance because the sibling agent compiles it with plain `swiftc`; policy types such as `OPConfig.swift:16-46` do conform. Keep guest-shared code in the lowest-common Swift dialect (`docs/CODING-STANDARDS.md:127-144`).
- `pbxproj` anchors. Neither project uses synchronized groups, so every new file needs all four anchors by hand: `PBXFileReference` plus `PBXBuildFile` plus `PBXGroup` membership plus phase membership (`AGENTS.md:46-51`). Never reorder unrelated sections.
- Wrong configuration. Only `Release` and `Nightly` exist (`Ophanim.xcodeproj/project.pbxproj:1132,1235`); `Debug` fails under `xcodebuild` (`.github/workflows/build.yml:28-30`).
- Dual-target drift. Host is Swift 6.0, Galgal guest is Swift 5.0 (`AGENTS.md:38-44`); the sibling split is normative in `OphanimCore/ring/OPRing.h:10-21`. Never re-interpose Galgal-owned `gg_SecItem*`; keychain stays embedded-only (`README.md:78-81`).
- R7 and R10 gate trips. No local `DYLD_INTERPOSE` defines outside `OphanimCore/compat/OPInterpose.h`; `PropertyListSerialization.propertyList` only in its four owners (`.github/workflows/build.yml:169-187`).
- Dead install reported as success. `install_app` must throw on timeout or validation failure; resource-only bundles without `Info.plist` (for example `Settings.bundle`) are skipped, never fatal (`docs/MCP-GUIDE.md:238-266`).
- Inspect silence. Turning Agent Mode on needs a relaunch; turning it off stops within one poll (`docs/INSPECT.md:23-27`). A moved view fails with take a fresh tree, never a guessed tap (`docs/CONTEXT.md:139-153`).

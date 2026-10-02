# Coding Standards — Documentation

How every Swift/Mach-C file in this repo documents itself. Adapted from
`CODING_DOCUMENTATION_GOLD_STANDARD_2026.md` (§6 why-not-what, §7
contract-not-tour, §12 templates) to this codebase's reality: Swift/DocC
(not JSDoc), dual-target guest+host compilation, and old-Swift-safe guest
files. Normative spellings live in `docs/CONTEXT.md` — this file records
only the documentation mechanics.

## 0. The 5 rules that matter most here

1. **Contract comments on every agent-read surface.** First sentence is the
   summary; then `what it does`, `args` (for MCP tools: the `args` dict
   keys), `returns`, `gotchas`, `throws` — because the MCP tools and the
   `OphanimCore/policy` types are read more by agents than by humans.
2. **Inline comments explain `why`, never `what`.** `// increment i` noise
   is deleted; one sentence per edge case or non-obvious choice, in the
   same commit as the code (gold standard §6).
3. **Swift DocC fields, not JSDoc.** `- Parameter name:`, `- Returns:`,
   `- Throws:` as top-level `///` list items [Confirmed — `apple/swift`
   `docs/DocumentationComments.md` via Context7, fetched 2026-10-02].
   `@param/@returns/@throws` never appear in Swift files.
4. **Dual-target/old-Swift callouts stay in the comment.** Anything that
   compiles into the guest must say so, and anything that duplicates code
   across the host/guest boundary must say why (see §4).
5. **Repo vocabulary, not synonyms.** `embedded`, `sibling`, `interpose`,
   `swizzle`, `vtable patch`, `inline hook`, `disposition`, `capture layer`
   per `docs/CONTEXT.md`. Never `hook` alone when you mean `inline hook`;
   never `DYLD_INSERT` when you mean `interpose`.

## 1. File headers

Every `.swift`/`.m`/`.h`/`.c` file starts with:

```swift
//
//  OPConfig.swift
//  OphanimCore
//
//  Per-app instrumentation configuration + interception rules. Written by the GUI into the
//  app's settings plist and read by the in-process agent at constructor time.
//
```

- Line 2: exact filename. Line 3: target (`Ophanim`, `OphanimCore`,
  `Galgal`), with a `(shared: guest engine + host app)` suffix when the
  file compiles into both (example: `OphanimCore/crash/OPCrashRecord.swift:1-3`).
- 1–4 lines of purpose: what the file owns and who reads/writes it. Not a
  tour of its contents.
- Host-only MCP tool files (`Ophanim/Core/MCP/Tools/...`) use target
  `Ophanim` and name their MCP surface, e.g. `Hook-installation tools.`
  (example: `HookTools.swift` header after the exemplar pass).

## 2. MARK section vocabulary

`// MARK: - <Name>`, one per concern, in file order. Use these names;
invent a new one only when none fits:

| MARK | Used for |
|---|---|
| `Init`, `Static`, `Instance State`, `Computed` | Type scaffolding (see `HostedApp.swift:11-50`) |
| `Matching`, `Action application` | Policy engine phases (`OPInterceptor.swift:91,103`) |
| `Codable` | Custom encode/decode (`OPEvent.swift:102`) |
| `Helpers` | Private support (`SourceTools.swift:80`, `OPAgent.swift:186`) |
| `Lifecycle`, `Launch`, `Management` | App start/stop/own (`HostedApp.swift:62`, `HostedApp+Power.swift:8`) |
| `Policies`, `Diff`, `Inspect` | Feature areas, as-is |
| `Live config watch` | Guest poll loops (`OPAgent.swift:139`) |

Keep the `// MARK: - X` dash form the repo already uses (37 host sites,
6 guest sites — don't reformat them).

## 3. Doc-comment style

### 3.1 Types and functions — the contract

```swift
/// Resolves a decision for a call. First matching rule wins.
///
/// Observe-by-default: with no matching rule the decision is `.observe`
/// and the original call runs untouched.
///
/// - Parameter ctx: The in-flight call description.
/// - Returns: The disposition plus any replacement payload.
public func decide(_ ctx: OPCallContext) -> OPDecision {
```

- `///`, never `/** */`. First sentence = summary (shows in Quick Help
  and the DocC index) [Confirmed — Apple "Writing symbol documentation
  in your source files", fetched 2026-10-02].
- Blank `///` line, then discussion: the constraint that forced any
  unusual choice, plus `gotchas` where behavior is non-obvious (e.g. the
  explicit-true `dryRun` contract on hook/rule writers,
  `HookTools.swift:5-9`).
- Fields, in this order, only where the gold standard demands them (§7):
  `- Parameter <name>:` for every parameter, `- Returns:` for
  non-`Void` returns, `- Throws:` for every `throws`. Either a
  `Parameters` section or separate `- Parameter` fields is accepted by
  DocC [Confirmed — same source]; this repo uses separate fields.
- MCP tool functions take one `args: [String: Any]` dict: document the
  expected keys inside `- Parameter args:` (`bundleID`, `dryRun`, plus
  tool-specific keys) and the JSON/string shape in `- Returns:`.
- `- Throws:` names the failure mode (`ToolRouter.bail` reason), not the
  error type.
- Struct fields that are themselves a contract (every `OPMatcher` glob,
  every `OPAction` payload) keep their trailing `//` one-liners
  (`OPConfig.swift:24-52`) — field-level `///` is reserved for types
  whose fields need a full sentence (hook structs, `OPConfig`).

### 3.2 Inline comments — why, not what

```swift
// Lowercase once: Swift matching is case-insensitive, JS indexOf is not.
```

Good (states the constraint). Bad: `// loop over domains` (repeats the
code). One sentence per edge case; updated in the same commit as the
code. Non-obvious `why` that needs more than a sentence (e.g. the local
`globMatch` copy, `OPConfig.swift:137-139`) gets a `///` on the symbol
instead.

### 3.3 What stays uncommented

Self-documenting names (`calculateMonthlyInterest`, `isAppRunning`),
`i++`-level trivia, and anything the type signature already says. If the
comment would repeat the name, delete the comment and improve the name.

## 4. Dual-target and old-Swift callouts

- `OPConfig.swift` + `OPEvent.swift` compile into host AND guest;
  `OPInterceptor.swift` is guest-only. Any helper the guest needs but
  cannot import (e.g. `OPImageScope.globMatch`, a local copy of
  `OPGlob.match`) carries a `///`/`//` stating exactly that
  (`OPConfig.swift:137-139`).
- Guest-compiled files stay in the lowest-common Swift dialect: the
  sibling agent builds some files with plain `swiftc` (no `-swift-version`
  flag), so no `Sendable` conformance or new-stdlib APIs there — the
  reason is recorded in the file header comment itself
  (`OPCrashRecord.swift:12-14`). Host app target is Swift 6.0, Galgal
  target is Swift 5.0 (`*.pbxproj` `SWIFT_VERSION`); new syntax must not
  leak into guest-shared files.
- `#if canImport(AppKit)` splits (host-only `NSWorkspace`/Installer
  paths in MCP tools, e.g. `AppTools.swift:11-16`) get a one-line `///`
  or `//` stating which side is which — agents must not "simplify" the
  `#else` branch away.

## 5. Naming (documentation-adjacent)

Names carry the information comments otherwise would (gold §5): tool
functions are verbs (`setObjcHooks`, `pruneFiles`), predicates read as
assertions (`isAppRunning`, `isActive`, `matches`), writers say what they
persist (`updateSettings`). MCP tool names are stable wire names owned
by `MCPServer.toolDefinitions` — never rename to match a comment.

## 6. Verification

```bash
swiftc -parse Ophanim/Core/MCP/Tools/Hooks/HookTools.swift  # per touched file
```

`swiftc -parse` (syntax only) on every touched file. No semantic
changes, no renames, no `pbxproj`/workflow edits in a doc pass.

## 7. Exemplar pass — done (2026-10-02, working tree only)

Brought fully into §3.1 conformance:

- `Ophanim/Core/MCP/Tools/Hooks/HookTools.swift` — headers + contracts
  on `setObjcHooks`/`setSwiftHooks`/`setInlineHooks`/`getHooks`.
- `Ophanim/Core/MCP/Tools/Hooks/RuleTools.swift` — contracts on
  `listPresets`/`applyPreset`/`setRules`/`validateRuleScript`/`presetRules`.
- `Ophanim/Core/MCP/Tools/Apps/AppTools.swift` — contracts on all 9 tools
  plus `isAppRunning`.
- `OphanimCore/policy/OPConfig.swift` — file header already conformant;
  contracts added on match/action/rule/hook/config types and
  `OPImageScope.matches`, `OPConfig.isActive`, `OPConfigLoader.load`,
  `OPPaths` helpers.
- `OphanimCore/policy/OPEvent.swift` — contracts on
  `currentThreadLabel`, `plainTextLine`, `encode`/`init(from:)`.
- `OphanimCore/policy/OPInterceptor.swift` — contracts on `decide`,
  `matches`, `apply`, `runScript`, `OPGlob.match`, `OPCallContext`.

## 8. Remaining dirs needing the same pass

- [ ] `Ophanim/Core/MCP/` — `MCPServer.swift`, `ToolRouter.swift`,
      `MCPTimeouts.swift`, `InspectGate.swift`
- [ ] `Ophanim/Core/MCP/Tools/Config/` — `ConfigTools.swift`
- [ ] `Ophanim/Core/MCP/Tools/Containers/` — `ContainerTools.swift`
- [ ] `Ophanim/Core/MCP/Tools/Events/` — `EventTools.swift`
- [ ] `Ophanim/Core/MCP/Tools/Inspect/` — `InspectTools.swift`
- [ ] `Ophanim/Core/MCP/Tools/Recon/` — `ReconTools.swift`
- [ ] `Ophanim/Core/MCP/Tools/Sources/` — `SourceTools.swift`
- [ ] `Ophanim/Core/MCP/Tools/Tweaks/` — `TweakTools.swift`
- [ ] `Ophanim/Core/MCP/Services/` — `AppQueryService`,
      `ContainerService`, `InspectService`, `ReportBuilder`,
      `SettingsStore`, `TweakStoreService`
- [ ] `Ophanim/Core/MCP/Transports/` — `StdioTransport`,
      `HTTPTransport`, `EventNotifier`
- [ ] `Ophanim/Core/Model/`, `Ophanim/Core/Services/`,
      `Ophanim/Core/Support/`, `Ophanim/Core/ViewModel/`
- [ ] `Ophanim/Features/` — AppLibrary, AppSettings, Install, KeyCover,
      Keymap, Onboarding, Recon, Rules, Sources
- [ ] `Ophanim/App/`, `Ophanim/DesignSystem/`, `Ophanim/Rules/`
- [ ] `OphanimCore/ring/`, `OphanimCore/bridge/`,
      `OphanimCore/hooks/boundary/`, `capture/`, `inline/`,
      `interpose/`, `OphanimCore/loader/`, `OphanimCore/crash/`,
      `OphanimCore/compat/`
- [ ] `TestApp/Sources/`, `scripts/` (shell: keep `why` comments,
      no DocC fields)
- [ ] `Galgal/` — upstream-owned runtime; document at boundaries only,
      do not reorganize

## Sources

- Gold standard: `/private/tmp/exmaple_standard/CODING_DOCUMENTATION_GOLD_STANDARD_2026.md`
  (v2026.1, 2026-08-31), §§1–15; glossary/reference under
  `exmaple_standard/reference/`.
- Swift DocC fields (`- Parameter`/`- Returns:`/`- Throws:`, Parameters
  section vs separate fields, mixable): `apple/swift`
  `docs/DocumentationComments.md` via Context7 [Confirmed 2026-10-02].
- First-sentence-as-summary / Quick Help: Apple "Writing symbol
  documentation in your source files" (`developer.apple.com`,
  `swift.org/documentation/docc/...`) [Confirmed 2026-10-02].
- Blog-derived statistics in the gold standard (Stack 58% reading time,
  GitClear duplication counts, Willow Voice 150 WPM): [unverified] —
  not re-fetched this session; rules above do not depend on them.
- Repo facts cited as `path:line`: `docs/CONTEXT.md`,
  `docs/ARCHITECTURE.md`, `OphanimCore/policy/*.swift`,
  `OphanimCore/crash/OPCrashRecord.swift:12-14`, `*.pbxproj`
  `SWIFT_VERSION`.

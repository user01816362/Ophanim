# AGENTS.md — Agent operating instructions for Ophanim

> **BLUF:** Ophanim is a Swift/macOS + iOS-Catalyst dual-target project (Xcode + SwiftPM/Carthage, GitHub Actions CI). You write host Swift 6.0 and guest Swift 5.0 in the same tree, every destructive MCP tool previews by default, and the project file has no synchronized groups — so new files need hand-placed anchors. Keep diffs small, cite `file:line` for every claim, and never change install/convert/sign/inject/launch semantics.

## 1. Read-first map

- `README.md` — product model: Embedded vs Sibling injection, capture matrix, build entry points.
- `docs/CONTEXT.md`, `docs/ARCHITECTURE.md` — system layout and why it is shaped that way.
- `docs/DECISIONS/` — accepted contracts; `0007-dryrun-safety-contract.md` is normative for tool behavior.
- `docs/RISKS.md`, `docs/INSPECT.md`, `docs/MCP-GUIDE.md` — risk posture and agent-mode surface.
- `Ophanim/Core/MCP/ToolRouter.swift:46` (`isDryRun`), `Ophanim/Core/MCP/MCPServer.swift` (catalog + rate limit), `Ophanim/Core/MCP/InspectGate.swift:6` (`requireLive` gate).
- `.github/workflows/build.yml` — the only CI workflow; read the step comments before touching build logic.
- `OphanimCore/ring/OPRing.h` SIBLING-MODE NOTE — normative for the Embedded/Sibling split.

## 2. Batch, commit, and CI rules

- Keep each change single-purpose and small; the log convention is one concern per commit (`git log --oneline`: `267579b`, `a5601f2`, `cf6b0aa`). Do not batch unrelated fixes.
- Commit subjects are imperative present tense with an optional area prefix (`Fix host-target scope: …`, `Hooks P5: …`, `MCP full coverage: …`). Match that shape.
- Do not commit unless asked; leave changes in the working tree and report.
- Only two build configurations exist: `Release` and `Nightly` (`Ophanim.xcodeproj/project.pbxproj:1132,1235`). `Debug` is named in the scheme but absent — `xcodebuild` fails on it. CI input offers only Release/Nightly.
- Toolchain is fixed: Apple Silicon, Xcode 26+, iOS SDK installed (`build.yml` "Verify toolchain"). A macOS-only toolchain cannot produce a working bundle.
- Before every push, run the gates CI runs, in this order:
  1. DRY grep gates (`build.yml` "DRY enforcement gates"): no local `DYLD_INTERPOSE` defines outside `OphanimCore/compat/OPInterpose.h` (R7); `PropertyListSerialization.propertyList` only in `PlistReader.swift`, `Entitlements.swift`, `EventPretty.swift`, `Uninstaller.swift` (R10).
  2. Inline-hook relocator self-test (`build.yml` "Inline-hook engine self-test": `clang -arch arm64 … scripts/test/reloctest.c`).
  3. `swiftc -parse` on every touched Swift file. Parse is syntax-only — it misses scope, cast, and C-enum errors — so also typecheck touched files and diff the typecheck result against the pristine `HEAD` baseline, plus a bridging-header probe for any C-interop expression.
  4. `./build-ophanim.sh Release`, then the bundle checks: `codesign --verify --deep --strict`, `vtool` Catalyst tag on `Galgal` + `OphanimAgent.dylib`, `Assets.car` present.
- Push/PR builds run on `main`, `v*` tags, PRs, and merge groups; `**/*.md` and `LICENSE` changes alone skip CI. Never cancel a tag run (immutable releases).

## 3. dryRun contracts

Two families; confusing them silently flips writes into previews or vice versa.

- **Default-true preview** (most destructive tools): `ToolRouter.isDryRun` (`Ophanim/Core/MCP/ToolRouter.swift:46`) returns `(args["dryRun"] as? Bool) ?? true`. Omitted `dryRun` previews; pass `dryRun:false` to execute. Each mutating handler branches before any mutation, and the catalog advertises the key (`Ophanim/Core/MCP/MCPServer.swift:588,601,615,628,639` and following). Adding a destructive tool means adding the branch plus the schema key in the same commit, or the catalog lies (`docs/DECISIONS/0007-dryrun-safety-contract.md:10-15`).
- **Explicit-true preview** (`set_*_hooks`, `set_rules`): omitted `dryRun` WRITES — the historical agent contract; only `dryRun:true` previews counts/validation without persisting (`Ophanim/Core/MCP/Tools/Hooks/HookTools.swift:12-16,34-35`, `Ophanim/Core/MCP/Tools/Hooks/RuleTools.swift:20-28`, `docs/DECISIONS/0007-dryrun-safety-contract.md:17-22`). `set_config` is a pure setter with no `dryRun` branch; unknown keys are rejected.
- **No preview exists** for gesture tools (`tap_element`, `swipe`, `set_text`, `inspect_pick` touch a live app) — deliberate exception, same decision file.
- Rate limit is 120 calls/minute per tool with a stated retry wait (`Ophanim/Core/MCP/MCPServer.swift:127-128`); refusals must state the wait so callers retry rather than guess.

## 4. Dual-target and old-Swift guest constraints

- Host app target: Swift 6.0, `MACOSX_DEPLOYMENT_TARGET = 26.0` (`Ophanim.xcodeproj/project.pbxproj:1142,1245,1093`).
- Galgal guest target: Swift 5.0 (`Galgal/Galgal.xcodeproj/project.pbxproj:1019,1049,1217,1261`). It builds for iOS, then `vtool`-retags to Mac Catalyst; CI fails the build if the tag is missing ("Verify bundle" step).
- `OphanimCore` (bridge, policy, ring, compat, hooks, loader, crash) compiles into BOTH targets. Keep guest-shared code in the old-Swift dialect: no Swift 6-only constructs, no new stdlib APIs without availability guards, no concurrency assumptions the Swift 5 compiler cannot check.
- Hard engine rules (from `README.md` capture matrix): the agent must never re-interpose Galgal-owned `gg_SecItem*` emulation; raw C filesystem capture chains through Galgal's dormant `gg_*`. Keychain stays Embedded-only by design.
- Never touch install/convert/sign/inject/launch behavior: `./build-ophanim.sh`, `scripts/deploy-runtime.sh`, `Galgal/build-galgal.sh`, `Galgal/build-agent.sh`, re-sign flow, `LC_LOAD_DYLIB` injection, Catalyst conversion, or any Swift/ObjC/C semantics. Comments, formatting, and safe renames of locals/private symbols only.

## 5. pbxproj anchor rules

- Neither project uses file-system synchronized groups (zero `PBXFileSystemSynchronized` entries in both `project.pbxproj` files). Every new file needs all four anchors placed by hand (or via Xcode, then verified): `PBXFileReference` + `PBXBuildFile` (e.g. `Ophanim.xcodeproj/project.pbxproj:10`) + `PBXGroup` membership + Sources/Resources/Frameworks phase membership. A file with only some anchors compiles nowhere or vanishes from the bundle.
- Never reorder unrelated sections; keep project diffs minimal and reviewable.
- Bump `MARKETING_VERSION` (`Ophanim.xcodeproj/project.pbxproj:1132,1235`) to cut the next release — published tags are immutable once released.
- The SwiftLint build phase degrades gracefully (`Ophanim.xcodeproj/project.pbxproj:819-836`, `Galgal/Galgal.xcodeproj/project.pbxproj:839-855`): if `swiftlint` is absent it logs `warning: SwiftLint not installed (lint skipped)`. CI runners do not install SwiftLint, so lint does not run in CI.

## 6. Comment, MARK, and naming conventions

- Comments explain why, not what (one sentence per edge case, same commit as the code). Doc comments on declarations follow Swift's Markdown dialect: first sentence is the summary.
- File headers: new files get a neutral purpose header (see `Ophanim/Core/Support/OphanimError.swift:1-7`). Never rewrite legacy `Created by …` attribution headers — they record provenance (PlayCover lineage); normalizing them would falsify history.
- `// MARK: - Section` dividers separate reads from mutations and group tool families. The MCP domain (`Ophanim/Core/MCP/`) is marked; see Gap G6 for the remaining backlog.
- Names carry meaning first: rename only locals and private symbols, never public API. Keep domain-conventional shorts (`x`/`y`/`w`/`h` coordinates and dimensions, `i` indices, `a`/`b` diff endpoints, `v` in 3-line validators) — renaming those is churn, not clarity. Fixed in the 2026-10-02 pass: `treeParams`, `memberIDs`, `candidateID`, `annotated`, `bookmark`, `group`, `manifest`, `summary`, `newComment`/`newTags`/`newNote`.

## 7. Evidence rules

- Every high-stakes claim cites `path:line` (in-scope code) or a footnote with absolute URL plus fetch date (out-of-scope sources). Confidence is labeled `[Confirmed]`, `[Inferred]`, or `[unverified]` — never implied.
- Do not fabricate APIs: a `[Confirmed]` claim means you reopened the code path (grep or file read) in this session.
- Write instructions in second person, present tense, active voice, sentence case headings, descriptive link text — per the Apple Style Guide (June 2026) and Google developer documentation style guide.
- New Markdown files follow the repo YAML front-matter convention where one exists; keep files under 600 lines or split them.

## 8. Gap list — the standard wants these; they need forbidden edits

Do not work around this list by editing forbidden files (`.github/workflows/*`, `*.xcodeproj/*`, `docs/*.md` content owned by the docs rewrite, install/convert/sign/inject/launch behavior, Swift/ObjC/C semantics). Fix the owning side first.

- **G1 — CI docs gate.** The gold standard wants `markdownlint-cli2` + `lychee` + `mmdc --validate` on every PR. Needs a new `.github/workflows/docs.yml`. Forbidden: workflow edits.
- **G2 — CI SwiftLint gate and pin.** Lint never runs in CI (no install step; phase skips). Needs a workflow step plus a version pin. Forbidden: workflow edits. Note: locally installed SwiftLint 0.65.1 cannot execute under this machine's Xcode 27 toolchain (SourceKitten `sourcekitdInProc` load crash, exit 133) — rule-pass claims below rest on pattern-absence greps, stated per rule.
- **G3 — Refused SwiftLint opt-in rules.** The 2026 recommended set is already the default-enabled set (verified: ~40 former opt-ins show enabled in 0.65.1 with no config entry); only `force_unwrapping` is explicitly opted in and `non_optional_string_data_conversion` stays disabled per upstream issue 5263. Refused with reason:
  - `contains_over_filter_count`: fires at `Ophanim/Features/AppSettings/TweakLibraryPane.swift:79` (`filter(\.isEnabled).count`). Fix needs a semantic edit — out of boundary.
  - `first_where`: fires at `Galgal/Galgal/GalgalScreen.swift:171` (`.filter({$0.isKeyWindow}).first`). Same reason.
  - `sorted_first_last`: fires at `Ophanim/Core/Services/OPCrashCorrelator.swift:40-45` (`.sorted { … }.last`). Same reason.
  - `empty_string`: fires 5× (`Ophanim/Core/Model/AppInfo.swift:184,192`, `Ophanim/Features/Install/IPA.swift:40`, `Ophanim/Features/KeyCover/KeyCoverSetupViews.swift:76,190`). `isEmpty` rewrite is semantic — out of boundary.
  - `fallthrough`: intentional use at `OphanimCore/hooks/capture/OPHooksNetwork.swift:164`. Rule bans all fallthrough.
  - `discouraged_assert`: intentional asserts at `Ophanim/Features/Install/Installer.swift:110`, `Ophanim/Core/Model/AppInfo.swift:263`, `Galgal/Galgal/Keymap/KeyCodeNames.swift:284`.
  - `missing_docs`, `explicit_acl`, `explicit_top_level_acl`, `explicit_type_interface`, `type_contents_order`, `file_header`, `no_magic_numbers`, `variable_shadowing`, `multiline_*`, `reduce_into`, `flatmap_over_map_reduce`, `identical_operands`: would fire widely or need execution to verify — refused until SwiftLint runs green in CI (G2).
- **G4 — File-header template.** The standard wants one enforced header; the repo mixes legacy `Created by …` attribution with new descriptive headers. A mass rewrite would falsify provenance. Needs an ADR before `file_header` can be enabled.
- **G5 — Test-framework rules** (`single_test_class`, `empty_xctest_method`, `balanced_xctest_lifecycle`): no XCTest targets exist (only `TestApp/` harness), so these pass vacuously and add nothing. Not enabled.
- **G6 — MARK backlog.** The MCP domain is marked (2026-10-02 pass). Roughly 100 files elsewhere (SwiftUI panes, `OphanimCore/hooks/*`, services) predate the convention. Deferred, not blocked — allowed edits, just not yet done.

## 9. Boundaries — always, ask, never

- **Always:** read the files in §1 before editing; cite `path:line`; keep `code` formatting for identifiers and `file:line` navigation refs; verify with `swiftc -parse` plus the §2 gate that fits the change.
- **Ask:** new MCP tools (need catalog + handler + dryRun branch in one commit), new interpose sites (R7 single-macro rule), new plist decode sites (R10 owner list), any `project.pbxproj` change.
- **Never:** change install/convert/sign/inject/launch behavior or language semantics; edit workflows or project files to route around gaps G1–G2; commit secrets (see `SECURITY.md`); claim a rule passes without either executing SwiftLint or a stated pattern-absence grep.

## 10. References (currency checked 2026-10-02)

- Swift API Design Guidelines, `https://swift.org/documentation/api-design-guidelines` — clarity at point of use, doc comment on every declaration, Swift Markdown dialect, `#fileID` over `#filePath` [Confirmed].
- SwiftLint rule set, local `swiftlint rules` on 0.65.1 (brew, 2026-10-02) — defaults absorb the 2026 recommended opt-ins; `force_unwrapping` stays opt-in by design [Confirmed]. Exact latest upstream release number [unverified].
- Apple Style Guide, June 2026, `https://support.apple.com/guide/applestyleguide` — address the reader as you; sentence case [Confirmed].
- Google developer documentation style guide, `https://developers.google.com/style` — second person, present tense, active voice, descriptive links [Confirmed].
- CWE-798 / CWE-259 (`https://cwe.mitre.org/data/definitions/798.html`) and MITRE ATT&CK T1694.002 / T1552 (`https://attack.mitre.org`) — secrets policy basis in `SECURITY.md` [Confirmed].

> Last analyzed: 2026-10-02 | SwiftLint: 0.65.1 (rule table only; lint execution crashes under Xcode 27 — see G2) | status: verified-by-construction (comments/renames only; `swiftc -parse` clean on all touched files)

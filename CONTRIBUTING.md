# Contributing

## Setup

You need an Apple Silicon Mac with Xcode 26 plus and the iOS platform installed (`README.md:85`). Clone, then verify the toolchain the same way CI does (`.github/workflows/build.yml:121-167`):

```sh
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
./build-ophanim.sh Release
```

Only `Release` and `Nightly` configurations exist; `Debug` fails (`AGENTS.md:20`). New to the project: read `AGENTS.md`, `docs/CONTEXT.md`, `docs/MCP-GUIDE.md`, `docs/CODING-STANDARDS.md`, and `docs/ARCHITECTURE.md` before editing (`AGENTS.md:5-14`).

## One batch, one commit, one build

Keep each change single-purpose and small; the log convention is one concern per commit with imperative present-tense subjects plus an optional area prefix (`AGENTS.md:17-18`). Do not commit unless asked; leave changes in the working tree and report (`AGENTS.md:19`).

## No stacking on red

Before every push, run the gates CI runs, in order (`AGENTS.md:22-26`):

1. DRY grep gates R7 and R10 (`.github/workflows/build.yml:169-187`).
2. Inline-hook relocator self-test (`clang -arch arm64 ... scripts/test/reloctest.c`).
3. `swiftc -parse` on every touched Swift file, plus a typecheck diff against pristine `HEAD` (parse alone misses scope, cast, and C-enum errors).
4. `./build-ophanim.sh Release`, then `codesign --verify --deep --strict`, the `vtool` Catalyst tag check, and `Assets.car` presence (`.github/workflows/build.yml:206-232`).

Do not stack new work on a failing gate, and never edit workflows or project files to route around a red gate (`AGENTS.md:67-84`).

## Docs-only changes skip CI

Pushes touching only `**/*.md` plus `LICENSE` skip CI (`.github/workflows/build.yml:60-62`). Keep them small and factual anyway; never cancel a tag run (`.github/workflows/build.yml:66-69`).

## dryRun and evidence rules for agent contributors

- Respect the two-family `dryRun` contract: most destructive tools default-true preview, hook and rule writers explicit-true preview, `set_config` and gestures have no preview (`docs/DECISIONS/0007-dryrun-safety-contract.md:10-22`, `docs/MCP-GUIDE.md:38-47`). A mutating tool without its catalog `dryRun` key is a bug.
- Every high-stakes claim cites `path:line`; label confidence `[Confirmed]`, `[Inferred]`, or `[unverified]`, never implied (`AGENTS.md:60-66`).
- Keep guest-shared code old-Swift-safe, keep `*.pbxproj` diffs minimal with all four anchors, and never change install, convert, sign, inject, or launch semantics (`AGENTS.md:38-51`).
- Never commit secrets; see `SECURITY.md:17-22`.

## Pull request checklist

- [ ] Single concern with an imperative subject line.
- [ ] Gates above run in order; failures listed explicitly (see `guides/02-debugging.md`).
- [ ] `file:line` citations on high-stakes claims; `[unverified]` where not re-read.
- [ ] `dryRun` branch plus catalog key ship in the same commit for any destructive tool.
- [ ] No workflow, `pbxproj` workaround, install-pipeline, or language-semantics change.
- [ ] Docs updated alongside code where the owning doc requires it.

## License

Distributed under the GPLv3 License; see `LICENSE`. By contributing you agree your changes ship under the same terms (`LICENSE:222-228`).

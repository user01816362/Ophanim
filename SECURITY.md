# SECURITY.md — Ophanim security policy

> **BLUF:** Ophanim is an authorized-use-only dynamic-analysis tool that re-signs and instruments iOS apps. It stores no credentials, signs ad-hoc, redacts captures by default, and previews destructive agent actions before executing. Report vulnerabilities privately via GitHub — never as a public issue.

## 1. Scope and authorized use

Ophanim runs iOS apps natively on Apple Silicon by re-signing them and hosting them as Mac Catalyst processes, then observes or intercepts behavior from inside (`README.md:6-10`). Use it only on software you own or are authorized to test — security research, app QA, CTF, your own dependencies (`README.md:39-42`). Re-signing breaks server-side attestation by design; defeating licensing or impersonating a genuine device to a server is out of scope and unsupported.

## 2. Reporting a vulnerability

This repo has no issue templates and no prior security policy (`.github/` contains only `workflows/build.yml` as of 2026-10-02).

- **Do not open a public issue** for anything that could weaken instrumentation integrity, leak captured data, or bypass the Agent-Mode gates.
- Report via **GitHub private vulnerability reporting** (repo → Security → Report a vulnerability), including: affected component, reproduction steps, and the `file:line` of the suspect code.
- You will get a confirmation and a remediation timeline; public disclosure waits for a fix.

## 3. Secrets policy

- **No stored credentials.** A tree-wide search (2026-10-02) finds no hardcoded API keys, tokens, or private keys — only the KeyCover master password held in view `@State` (user-supplied, memory-only: `Ophanim/Features/KeyCover/KeyCoverViews.swift:11`) and the sudo password piped per-invocation below. Basis: CWE-798 (use of hard-coded credentials) and CWE-259; MITRE ATT&CK T1694.002 / T1552.
- **Sudo password handling** (`Ophanim/Core/Support/Shell.swift:45-81`): the password arrives as a call argument, is encoded once with a trailing newline (`Shell.swift:45-46`), written to the `sudo -S` stdin pipe (`Shell.swift:76-77`), and the handle is closed immediately to avoid hangs on wrong passwords (`Shell.swift:80-81`). It is never written to disk, never logged, and never embedded in a command string (no shell interpolation — the password travels a pipe, not `sh -c`).
- **Keychain and crypto are observe-only.** `SecItem*` access and `CCCrypt`/`CCHmac` are captured through the lock-free ring after the call returns; the engine cannot modify them and never persists key material (`README.md:31-37`).
- Never commit secrets. If one lands in the tree, rotate it and rewrite history — do not just delete the line.

## 4. Signing and entitlements

- Builds are **ad-hoc signed, leaf-first** (never `codesign --deep` for signing, per TN2206): nested pieces first, then the bundle, then verify (`build-ophanim.sh:22-28` for the build tree, `:39-42` for the `~/Applications` install).
- Both entitlements files contain an **empty dict** as of 2026-10-02 (`Ophanim/Ophanim.entitlements`, `Ophanim/OphanimRelease.entitlements`; referenced at `Ophanim.xcodeproj/project.pbxproj:248,270`, applied at `:1113,1216`). Any new entitlement must be justified in the commit message and mirrored here.
- **Install location is enforced at runtime**: the app expects to live at `/Applications/Ophanim.app` (`Ophanim/Core/Support/AppIntegrity.swift:34`) and treats Xcode build paths as the only other legitimate home (`AppIntegrity.swift:36-38`); `verifyAppIntegrity` (`AppIntegrity.swift:12-13`) re-checks on demand.
- CI verifies the shipped bundle independently: `codesign --verify --deep --strict` plus the `vtool` Mac Catalyst tag check on `Galgal` and `OphanimAgent.dylib` (`build.yml` "Verify bundle"). Non-nightly releases additionally get Sigstore provenance attestation (`build.yml` "Attest build provenance", `actions/attest@v4`).

## 5. Redaction contract

- Captures redact by default. Every inspect-family tool passes the single gate `InspectGate.requireLive` (`Ophanim/Core/MCP/InspectGate.swift:6`), which returns the effective `redacted` flag alongside the config (`InspectGate.swift:19`).
- Raw capture is opt-in per app via `inspectDisableRedaction` on `OPConfig` (default off — redaction on). The disable toggle lives under Agent Mode, so a guest app cannot turn off its own redaction.
- Sinks are NDJSON, plain text, and `os_log`; snapshots pin trees to disk with content hashes so listings stay metadata-only (`Ophanim/Core/MCP/Tools/Inspect/InspectTools.swift` manifest helpers). Treat any log, snapshot, or screenshot as sensitive data: do not paste captures into issues, prompts, or commits.

## 6. Agent-surface safety

- Destructive MCP tools preview by default (`ToolRouter.isDryRun`, `Ophanim/Core/MCP/ToolRouter.swift:46`); hook/rule writers use explicit-true preview. See `AGENTS.md` §3 for the two families — a tool that mutates without advertising `dryRun` in its catalog entry is a security bug, not a UX gap.
- Per-tool rate limiting (120/minute with stated retry, `Ophanim/Core/MCP/MCPServer.swift:127-128`) bounds chatty or compromised clients.
- Agent Mode is a host-side setting per app; Inspect refuses with a stated fix when it is off — never with an empty result that looks like success.

## 7. Supply chain

- Five SwiftPM dependencies are pinned in the project files (Yams, DownloadManager, DataCache, Injection, SwiftSoup — see `build.yml` "Cache SwiftPM" comment); CI keys its cache on the project files so pin changes invalidate it.
- Vendored code ships in-tree: the runtime's PTFakeTouch copy and the `inject` Mach-O tooling (see `README.md` acknowledgments). Audit vendored copies on update; they are covered by the ad-hoc signature, not by upstream release verification.

> Last updated: 2026-10-02 | entitlements: empty dict (both files) | signing: ad-hoc leaf-first | status: verified against tree

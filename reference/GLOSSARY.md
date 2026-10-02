# Glossary

Single project vocabulary. One-line definitions only. Normative spellings live in `docs/CONTEXT.md:5-16`; documentation mechanics live in `docs/CODING-STANDARDS.md:10-29`. This file deduplicates against both: link, do not fork.

| Term | Definition | Owner |
|---|---|---|
| `embedded` | Engine runs inside the Galgal runtime already in the app (default, full capture, no extra re-sign). | `docs/CONTEXT.md:7`, `README.md:56-57` |
| `sibling` | Standalone agent dylib injected alongside Galgal via a second `LC_LOAD_DYLIB`, re-signed. | `docs/CONTEXT.md:8`, `README.md:58-60` |
| `interpose` | `DYLD_INTERPOSE` rebinding of C symbols; only via `OphanimCore/compat/OPInterpose.h`, never redefined (R7). | `docs/CONTEXT.md:9`, `.github/workflows/build.yml:169-187` |
| `swizzle` | Objective-C `method_exchange` hooking (high-level filesystem via `NSFileManager`). | `docs/CONTEXT.md:10`, `docs/ARCHITECTURE.md:51-57` |
| `vtable patch` | Hooking native-Swift methods at the vtable (reaches non-`@objc` Swift, devirtualized `-O` code excepted). | `docs/CONTEXT.md:11`, `docs/MCP-GUIDE.md:98` |
| `inline hook` | Tier-3 arm64 machine-code patch plus trampoline arena, by address, symbol, module plus offset, or byte signature. | `docs/CONTEXT.md:12`, `docs/ARCHITECTURE.md:14-21` |
| `disposition` | Policy decision per call: observe, block, delay, fault, modify, replace, or script. | `docs/CONTEXT.md:14`, `OphanimCore/policy/OPInterceptor.swift:84-89` |
| `capture layer` | One of network, keychain, crypto, filesystem, process, or device. | `docs/CONTEXT.md:15`, `README.md:64-76` |
| `redaction` | Captures mask sensitive values by default; raw capture needs per-surface consent (`inspectDisableRedaction`, `redactionKeys`). | `docs/CONTEXT.md:131-137`, `SECURITY.md:31-35` |
| `dryRun default-true` | Most destructive tools: omitted `dryRun` previews, `dryRun:false` executes (`ToolRouter.swift:46`). | `docs/DECISIONS/0007-dryrun-safety-contract.md:10-15`, `AGENTS.md:29-36` |
| `dryRun explicit-true` | `set_*_hooks`, `set_rules`, `apply_preset`: omitted `dryRun` writes, only `dryRun:true` previews. | `docs/DECISIONS/0007-dryrun-safety-contract.md:17-22`, `docs/MCP-GUIDE.md:38-47` |
| `snapshot pin` | Bookmark-held snapshot that survives launch sweeps and keep-20 pruning; removal unpins. | `docs/INSPECT.md:162-169`, `docs/MCP-GUIDE.md:183-195` |
| `Galgal` | Injected in-process runtime: iPad emulation plus compatibility layer, hosts the engine in embedded mode. Upstream-owned. | `README.md:51`, `docs/ARCHITECTURE.md:11-13` |
| `ChainGuard` | Per-app keychain replacement that fixes login breakage from re-signing; toggleable per app, off by default [unverified: default]. | `Galgal/README.md:49-51`, `docs/PLANS/01-crash-advisor.md:26` |
| `churn` | Renames that add noise without meaning (for example domain shorts `x`/`y`/`w`/`h`, `i`, `a`/`b`, `v`); prohibited. | `AGENTS.md:53-59` |
| `preset` | Named canned rule set: `block-trackers`, `fake-idfv`, `fake-idfa`. | `docs/MCP-GUIDE.md:227-231` |

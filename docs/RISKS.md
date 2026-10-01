# Risks & Tech Debt

| Risk | Owner | Recheck |
|---|---|---|
| Capability matrix drift (README vs `OPRing.h` vs `integration-test.sh`) | maintainer | monthly |
| `Galgal/README.md` Carthage flow is stale (upstream file, do not edit here) | maintainer | on Galgal bump |
| arm64e refusal is runtime-only; x86_64/arm64e builds fail late | engine | on toolchain bump |
| `URLSession` policy path untested in CI (hardened waits unverified) | maintainer | after CI wiring |
| `Cartfile` floating `master` vs resolved `v3.1.0`; no carthage binary invoked | maintainer | on Galgal bump |
| Catalyst window disagreement resolved to single `OPConstants.h` — scripts must adopt | maintainer | this cleanup |
| Inspect command slot is per-process (`NSLock`): two concurrent `--mcp` children can collide; fix is a file lock on the slot | engine | with Agent-Mode batch |
| Loopback MCP HTTP is open to any local process (same-machine trust, current behavior — `HTTPTransport.swift:18-20`); token gate covers non-loopback only | maintainer | on auth review |
| Swift vtable hooks capped at 16 per process, fixed pool, no runtime codegen (`OPHooksSwift.swift:16,24`); overflow returns `pool-full` | engine | when hook demand grows |
| Inline trampoline pages quarantined-never-reclaimed; safe-reclaim design (global quiescence + hot-path busy counter) deliberately unwired until a live hook-removal feature justifies the cost (`OPInline.c:398-414`) | engine | with hook-removal feature |
| No-preview exceptions are deliberate, not gaps: gestures (`tap/swipe/set_text` cases carry no `isDryRun` — `InspectTools.swift:89-161`) and pure setters / hook+rule full-replacements (`HookTools.swift:5-29`, `RuleTools.swift:28-34` have no dryRun branch; contract in ADR-0007) | maintainer | when adding a destructive tool |

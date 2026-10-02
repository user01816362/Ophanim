# Risks & Tech Debt

| Risk | Owner | Recheck |
|---|---|---|
| Capability matrix drift (README vs `OPRing.h` vs `integration-test.sh`) | maintainer | monthly |
| `Galgal/README.md` Carthage flow is stale (upstream file, do not edit here) | maintainer | on Galgal bump |
| arm64e refused at compile time (`OPInline.c:17-21` `#error`) plus runtime image check (`OPInline.c:229-232,317`); x86_64 builds still fail late | engine | on toolchain bump |
| `URLSession` policy path untested in CI (hardened waits unverified) | maintainer | after CI wiring |
| `Cartfile` floating `master` vs resolved `v3.1.0`; no carthage binary invoked | maintainer | on Galgal bump |
| Catalyst window disagreement resolved to single `OPConstants.h` — scripts must adopt | maintainer | this cleanup |
| Inspect command slot is per-process (`NSLock`, `InspectService.swift:16`, held whole-transaction `:91-96`): two concurrent `--mcp` children can collide; fix is a file lock on the slot | engine | with Agent-Mode batch |
| Loopback MCP HTTP is open to any local process (same-machine trust, current behavior — `HTTPTransport.swift:19-30`); token gate covers non-loopback only | maintainer | on auth review |
| Swift vtable hooks capped at 16 per process, fixed pool, no runtime codegen (`OPHooksSwift.swift:24`, pool reuse `:29-30`); overflow returns `pool-full` (`:124`) | engine | when hook demand grows |
| Inline trampoline pages quarantined-never-reclaimed; safe-reclaim design (global quiescence + hot-path busy counter) deliberately unwired until a live hook-removal feature justifies the cost (`OPInline.c:401-414`) | engine | with hook-removal feature |
| No-preview exceptions are deliberate, not gaps: gestures (`tap/swipe/set_text/inspect_pick` cases carry no `isDryRun` — `InspectTools.swift:89-161`) and pure setters / hook+rule writers with explicit-true preview (omitted = write, the historical contract — `HookTools.swift:5-9`, `RuleTools.swift:20-28,42-44`; contract in ADR-0007) | maintainer | when adding a destructive tool |
| Catalog drift: 83 tools across 3 routers (`MCPServer.swift:241`, `ToolRouter.swift:85-151`, `InspectTools.swift:740-749`); any new tool must land in the catalog + router + readOnly/destructive sets together or annotations lie | maintainer | when adding a tool |

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

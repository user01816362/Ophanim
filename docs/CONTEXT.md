# Context & Glossary

Normative spellings. Every ADR and header comment must use these.

| Term | Meaning |
|---|---|
| embedded | Galgal.framework loaded in the hosted app |
| sibling | OphanimAgent.dylib injected alongside, second LC_LOAD_DYLIB |
| interpose | DYLD_INTERPOSE rebinding (use `OPInterpose.h`, never redefine) |
| swizzle | ObjC method_exchange (high-level FS via NSFileManager) |
| vtable patch | Swift/static-dispatch hook |
| inline hook | Tier-3 arm64 machine-code patch + trampoline arena |
| ring producer/consumer | `op_ring_emit` (any-context, no alloc/lock/ObjC) → consumer thread → `OPRingBridge.emitKind` |
| disposition | observe / block / delay / fault / modify / replace / script |
| capture layer | network / keychain / crypto / filesystem / process / device |
| bypass-vs-logging | pinning/JB bypass changes app behavior to observe it; always an explicit tradeoff, recorded in an ADR |

Ownership: Keychain = Galgal-owned. FS raw POSIX = sibling-only
(`OPHooksFSRaw.m`, `-D OPHANIM_SIBLING`). No-double-interpose rule.

## MCP agent surface (ported from OLD MCP-GUIDE)
- One `--mcp` child per connected client is normal (pipes are per-process).
  State shared across children/GUI is file-backed (settings plists, NDJSON
  logs, inspect slot); in-memory state does NOT cross processes.
- Rate limit 120/min per tool: wait out the stated retry, don't hammer.
- Every result carries `structuredContent` mirrored as text JSON — read either.
- Failures are `isError: true` with self-correcting messages, except unknown
  tool names (also `isError`, friendlier than `-32602` — fix the name).
- `dryRun` defaults true on mutating tools (except pure setters and tap/swipe):
  preview first, then re-call `dryRun: false`.
- First calls: `list_apps` → bundle IDs, `get_config` before mutating.

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

# 0001 Ring producer constraints

Status: Accepted (2026-09-30, cleanup ratification of existing design).

Context: Hooks fire in any thread context, including post-fork and inside
malloc. Producer-side code cannot allocate, lock, or touch ObjC.

Decision: `op_ring_emit` uses atomics + memcpy only. Consumer thread does all
allocation and Swift bridging. `OPReentry` guards every `log()` path.

Consequences: Producers stay tiny and auditable. Debugging producer drops
requires ring-level tracing, not app logs.

# 0012 Hook lifecycle (P1–P6), tool-surface growth, install hardening

Status: Accepted (2026-10-02, HEAD `267579b` — ratification of landed work).

Context: Since ADR-0007 the hook engine gained script state, inline arg
rewrites, dyld retry, install accounting, bounded revert, and image scoping
(P1–P6); the MCP surface grew 63 → 83 tools; installs learned to fail loudly.
None of it was written down. Engine semantics live in `ARCHITECTURE.md`
(hook engine section); this ADR records the *decisions*.

Decision:

- P1 script state over new plumbing: per-rule `ctx.state.*` capped
  (32 keys × 256 chars, reset on reload) instead of a host round-trip —
  `decide()` stays synchronous.
- P2 inline arg edits on RESUME (`cannedArgs` → x0–x7, else body-bytes → x0)
  rather than forcing REPLACE — the original still runs.
- P3 dyld image-add retry flag drained by the existing config poll — no new
  thread, no constructor work.
- P4 aggregate install failures into one `installSummary` event; `image-mismatch`
  recorded, never fatal.
- P5 bounded revert on reload (`removeNotIn` before install on all three tiers;
  quarantine-not-free for inline pages) — no thread suspension, ever.
- P6 `imageGlob` opt-in scoping, nil/empty-means-all (zero cost when unused).
- Tool growth ships in domain files under `Tools/` with catalog + router +
  annotation sets updated in the same commit (see `RISKS.md` catalog-drift row).
  Hook/rule writers keep omitted-writes (ADR-0007 note).
- Install seal: skip resource-only bundles (Settings.bundle has no code to
  sign) but throw on a broken top-level seal — a dead app that "installed" is
  worse than a stated failure.
- Debugger flags (`openWithLLDB`, `openLLDBWithTerminal`) persist in
  `AppSettingsData` and are `set_config` keys, so headless clients can manage
  them like any other setting.

Consequences: P5 removal events (`ophanim.objcHook.remove`, …) are observable
in the event stream. Revert paths must stay main-thread-only like the reload
that drives them. Anything unverifiable about guest Swift version
compatibility is marked `[unverified]` in the docs, not asserted.

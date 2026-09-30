# 0003 Inline-hook engine choice

Status: Accepted (2026-09-30, cleanup ratification).

Context: Interpose cannot rebind intra-shared-cache calls; some targets need
machine-code patching.

Decision: Tier-3 arm64 inline engine (`OPInline.c` + `OPInlineAsm.s`,
trampoline arena, quarantine — never unmap mid-trampoline). arm64e refused
at runtime (`OP_INLINE_ERR_ARM64E`).

Consequences: arm64-only. `reloctest.c` gates every build. Compile-time arch
gate is future work.

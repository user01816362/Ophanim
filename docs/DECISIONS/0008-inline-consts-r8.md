# 0008 Inline-trampoline constants + R8

Status: Accepted (2026-10-01).

Context: `OPInlineAsm.s` hardcoded every frame/record offset (`#0xF8`, `#0x1A0`…)
while `OPCpuContext` (`OPInline.h`) and `OPHookRecord` (`OPInline.c`) carried the
same numbers in comments. A struct edit that moves an offset without moving the
asm reads garbage in a live-patched process — the highest-blast-radius drift in
the repo.

Decision: The `.s` uses one `.equ` block (CTX_*/REC_*/FRAME_SIZE/DISP_*); no raw
`#` immediates elsewhere. `OPInline.c` carries `_Static_assert`s on every shared
offset/size, so a C-side move fails the build. Conversion was proven
semantics-preserving: `__text` bytes identical before/after (modulo symtab labels).

R8 (for later `build.yml` wiring — yml untouched by this change): fail when any
`#0` immediate appears outside `.equ`/comment lines:
`grep -nE '#0' OPInlineAsm.s | grep -vE '\.equ|^\s*[0-9]+:\s*//'` must print nothing.

Consequences: Device proof (patched functions still redirect on arm64) stays a
nightly-device item; CI proves syntax (assembles), layout (asserts), and naming (R8).

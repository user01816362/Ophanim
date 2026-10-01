//
//  OPInlineAsm.s
//  OphanimCore
//
//  Shared trampoline thunk for the Tier-3 inline hook engine (see OPInline.h / OPInline.c). One copy,
//  shared by every hook. The per-hook stub (generated in the arena) sets x16 = &OPHookRecord and
//  branches here. This saves the full CPU context, calls the Swift dispatcher, then either resumes
//  into the call-original trampoline (RESUME) or returns to the caller with handler-set x0..x7
//  (REPLACE). x16/x17 (IP0/IP1) are dead at a function entry, so the per-hook stub may clobber them.
//
//  The frame offsets here MUST match `OPCpuContext` in OPInline.h, and the record offsets (call_orig
//  @ +0x00, target @ +0x08, hook_id @ +0x10) MUST match OPHookRecord in OPInline.c.
//
//  arm64 only.

#if defined(__arm64__) || defined(__aarch64__)

.text
.p2align 2
.globl _op_inline_shared_entry
_op_inline_shared_entry:
    // Named frame/record/dispatch constants. MUST match OPCpuContext (OPInline.h) and
    // OPHookRecord (OPInline.c); C-side _Static_asserts lock those layouts. R8 bans raw
    // # immediates below (grep: '#0' outside .equ/comment lines fails the build).
    .equ CTX_X0, 0x00
    .equ CTX_X1, 0x08
    .equ CTX_X2, 0x10
    .equ CTX_X4, 0x20
    .equ CTX_X6, 0x30
    .equ CTX_X8, 0x40
    .equ CTX_X10, 0x50
    .equ CTX_X12, 0x60
    .equ CTX_X14, 0x70
    .equ CTX_X16, 0x80
    .equ CTX_X18, 0x90
    .equ CTX_X20, 0xA0
    .equ CTX_X22, 0xB0
    .equ CTX_X24, 0xC0
    .equ CTX_X26, 0xD0
    .equ CTX_X28, 0xE0
    .equ CTX_X30, 0xF0
    .equ CTX_SP, 0xF8
    .equ CTX_PC, 0x100
    .equ CTX_NZCV, 0x108
    .equ CTX_Q0, 0x110
    .equ CTX_Q2, 0x130
    .equ CTX_Q4, 0x150
    .equ CTX_Q6, 0x170
    .equ CTX_STASH, 0x190
    .equ FRAME_SIZE, 0x1A0
    .equ REC_CALL_ORIG, 0x00
    .equ REC_TARGET, 0x08
    .equ REC_HOOK_ID, 0x10
    .equ DISP_REPLACE, 1
    .equ DISP_LEAVE, 2
    // x16 = &OPHookRecord on entry.
    sub  sp, sp, #FRAME_SIZE
    stp  x0,  x1,  [sp, #CTX_X0]
    stp  x2,  x3,  [sp, #CTX_X2]
    stp  x4,  x5,  [sp, #CTX_X4]
    stp  x6,  x7,  [sp, #CTX_X6]
    stp  x8,  x9,  [sp, #CTX_X8]
    stp  x10, x11, [sp, #CTX_X10]
    stp  x12, x13, [sp, #CTX_X12]
    stp  x14, x15, [sp, #CTX_X14]
    stp  x16, x17, [sp, #CTX_X16]
    stp  x18, x19, [sp, #CTX_X18]
    stp  x20, x21, [sp, #CTX_X20]
    stp  x22, x23, [sp, #CTX_X22]
    stp  x24, x25, [sp, #CTX_X24]
    stp  x26, x27, [sp, #CTX_X26]
    stp  x28, x29, [sp, #CTX_X28]
    str  x30,      [sp, #CTX_X30]
    add  x9, sp, #FRAME_SIZE
    str  x9,       [sp, #CTX_SP]        // ctx->sp = caller sp at function entry
    ldr  x9,  [x16, #REC_TARGET]
    str  x9,       [sp, #CTX_PC]       // ctx->pc = record->target
    mrs  x9,  NZCV
    str  x9,       [sp, #CTX_NZCV]       // ctx->nzcv
    stp  q0,  q1,  [sp, #CTX_Q0]
    stp  q2,  q3,  [sp, #CTX_Q2]
    stp  q4,  q5,  [sp, #CTX_Q4]
    stp  q6,  q7,  [sp, #CTX_Q6]
    str  x16,      [sp, #CTX_STASH]       // stash &record across the call (x16 is caller-clobberable)

    ldr  w0,  [x16, #REC_HOOK_ID]            // arg0 = record->hook_id
    mov  x1,  sp                      // arg1 = &ctx
    bl   _op_inline_dispatch          // -> Swift @_cdecl; returns RESUME(0)/REPLACE(1) in w0

    ldr  x16, [sp, #CTX_STASH]            // reload &record (does not touch w0)
    cmp  w0,  #DISP_REPLACE
    b.eq Lop_inline_replace
    cmp  w0,  #DISP_LEAVE
    b.eq Lop_inline_leave             // RESUME_LEAVE: run original via BL, then leave-dispatch

    // ---- RESUME: restore (possibly arg-modified) state, jump to the call-original trampoline ----
    ldr  x9,  [sp, #CTX_NZCV]
    msr  NZCV, x9
    ldp  q0,  q1,  [sp, #CTX_Q0]
    ldp  q2,  q3,  [sp, #CTX_Q2]
    ldp  q4,  q5,  [sp, #CTX_Q4]
    ldp  q6,  q7,  [sp, #CTX_Q6]
    ldp  x0,  x1,  [sp, #CTX_X0]
    ldp  x2,  x3,  [sp, #CTX_X2]
    ldp  x4,  x5,  [sp, #CTX_X4]
    ldp  x6,  x7,  [sp, #CTX_X6]
    ldp  x8,  x9,  [sp, #CTX_X8]
    ldp  x10, x11, [sp, #CTX_X10]
    ldp  x12, x13, [sp, #CTX_X12]
    ldp  x14, x15, [sp, #CTX_X14]
    ldp  x18, x19, [sp, #CTX_X18]        // skip x16/x17 (scratch; keep x16 = &record)
    ldp  x20, x21, [sp, #CTX_X20]
    ldp  x22, x23, [sp, #CTX_X22]
    ldp  x24, x25, [sp, #CTX_X24]
    ldp  x26, x27, [sp, #CTX_X26]
    ldp  x28, x29, [sp, #CTX_X28]
    ldr  x30,      [sp, #CTX_X30]
    ldr  x17, [x16, #REC_CALL_ORIG]            // call_orig trampoline
    add  sp, sp, #FRAME_SIZE
    br   x17

Lop_inline_replace:
    // ---- REPLACE: return to the caller with handler-set x0..x7; the original never runs ----
    ldr  x9,  [sp, #CTX_NZCV]
    msr  NZCV, x9
    ldp  q0,  q1,  [sp, #CTX_Q0]
    ldp  q2,  q3,  [sp, #CTX_Q2]
    ldp  q4,  q5,  [sp, #CTX_Q4]
    ldp  q6,  q7,  [sp, #CTX_Q6]
    ldp  x0,  x1,  [sp, #CTX_X0]        // x0/x1 = handler-set return value(s)
    ldp  x2,  x3,  [sp, #CTX_X2]
    ldp  x4,  x5,  [sp, #CTX_X4]
    ldp  x6,  x7,  [sp, #CTX_X6]
    ldp  x8,  x9,  [sp, #CTX_X8]
    ldp  x10, x11, [sp, #CTX_X10]
    ldp  x12, x13, [sp, #CTX_X12]
    ldp  x14, x15, [sp, #CTX_X14]
    ldp  x18, x19, [sp, #CTX_X18]        // restore callee-saved x19..x29 (we stand in for the function)
    ldp  x20, x21, [sp, #CTX_X20]
    ldp  x22, x23, [sp, #CTX_X22]
    ldp  x24, x25, [sp, #CTX_X24]
    ldp  x26, x27, [sp, #CTX_X26]
    ldp  x28, x29, [sp, #CTX_X28]
    ldr  x30,      [sp, #CTX_X30]
    add  sp, sp, #FRAME_SIZE
    ret

Lop_inline_leave:
    // ---- RESUME_LEAVE: BL the original (it returns back here), then call leave-dispatch ----
    // Restore the (possibly arg-modified) registers for the original, but keep x16 = &record and our
    // frame (sp). x30 is NOT restored - BLR sets it so the original returns to us.
    ldr  x9,  [sp, #CTX_NZCV]
    msr  NZCV, x9
    ldp  q0,  q1,  [sp, #CTX_Q0]
    ldp  q2,  q3,  [sp, #CTX_Q2]
    ldp  q4,  q5,  [sp, #CTX_Q4]
    ldp  q6,  q7,  [sp, #CTX_Q6]
    ldp  x0,  x1,  [sp, #CTX_X0]
    ldp  x2,  x3,  [sp, #CTX_X2]
    ldp  x4,  x5,  [sp, #CTX_X4]
    ldp  x6,  x7,  [sp, #CTX_X6]
    ldp  x8,  x9,  [sp, #CTX_X8]
    ldp  x10, x11, [sp, #CTX_X10]
    ldp  x12, x13, [sp, #CTX_X12]
    ldp  x14, x15, [sp, #CTX_X14]
    ldp  x18, x19, [sp, #CTX_X18]
    ldp  x20, x21, [sp, #CTX_X20]
    ldp  x22, x23, [sp, #CTX_X22]
    ldp  x24, x25, [sp, #CTX_X24]
    ldp  x26, x27, [sp, #CTX_X26]
    ldp  x28, x29, [sp, #CTX_X28]
    ldr  x17, [x16, #REC_CALL_ORIG]            // call_orig trampoline (x16 = &record still valid)
    blr  x17                          // run the original; it RETs back here with x0/x1 = return value
    str  x0,  [sp, #CTX_X0]             // ctx->x[0] = return value (blr clobbered caller-saved incl x16)
    str  x1,  [sp, #CTX_X1]             // ctx->x[1]
    ldr  x16, [sp, #CTX_STASH]            // reload &record
    ldr  w0,  [x16, #REC_HOOK_ID]            // hook_id
    mov  x1,  sp                      // &ctx
    bl   _op_inline_dispatch_leave    // may modify ctx->x[0..1]
    ldp  x0,  x1,  [sp, #CTX_X0]        // (possibly modified) return value
    ldr  x30,      [sp, #CTX_X30]        // real caller (saved at function entry)
    add  sp, sp, #FRAME_SIZE
    ret

#endif /* arm64 */

// OPConstants.h — single constants table for the guest engine.
// C-visible source of truth. Swift mirrors (OPRingBridge.Kind raw values,
// Catalyst floors, PLATFORM_IOS) must match these; CI asserts sync.
// New magic numbers belong here, not inline in .c/.s/.swift.
#ifndef OPHANIM_CONSTANTS_H
#define OPHANIM_CONSTANTS_H

// Ring value caps (mirror required in OPRingBridge.swift).
#define OP_STR_CAP 208
#define OP_BLOB_CAP 256

// Inline-hook CPU context offsets (consumed by OPInline.h struct comments
// and OPInlineAsm.s immediates via .equ — keep in sync).
#define OP_INLINE_CTX_SP    0x0F8
#define OP_INLINE_CTX_PC    0x100
#define OP_INLINE_CTX_X0    0x108
#define OP_INLINE_CTX_X1    0x110
#define OP_INLINE_CTX_FP    0x190

// Platform + Catalyst window (single source; build scripts must agree).
#define OPHANIM_PLATFORM_IOS 2
#define OPHANIM_CATALYST_FLOOR_MAJOR 14
#define OPHANIM_CATALYST_FLOOR_MINOR 0
#define OPHANIM_CATALYST_CEIL_MAJOR 26
#define OPHANIM_CATALYST_CEIL_MINOR 0

#endif

# 0002 Sibling-split symbol ownership

Status: Accepted (2026-09-30, cleanup ratification).

Context: Embedded (Galgal.framework) and sibling (OphanimAgent.dylib) can
load in the same process. Collisions cause silent double-hooks.

Decision: `-D OPHANIM_SIBLING` renames the entry class to
`OPAgentBootstrap` and activates agent-only interposes (`OPHooksFSRaw.m`).
Keychain stays Galgal-owned. No-double-interpose rule.

Consequences: Ownership is compile-time, not convention. New hooks must
declare their image in the file header.

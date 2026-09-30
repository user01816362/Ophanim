# 0006 Sibling filesystem parity

Status: Accepted (2026-09-30).

Context: README's capability matrix said sibling filesystem capture was
"partial - NSFileManager only" and that raw C-level filesystem stayed
Embedded-only. OPRing.h's SIBLING-MODE NOTE and OPHooksFSRaw.m (agent-only,
-D OPHANIM_SIBLING, chains through Galgal's dormant gg_*) say sibling
captures raw C-level open/stat/access/rename/unlink too.

Decision: The header is normative for mechanism. Sibling has filesystem
parity (raw observe + NSFileManager swizzle). README updated to match;
integration-test.sh already asserts the filesystem category.

Consequences: Any future FS-coverage change updates README + OPRing.h note +
integration-test.sh in the same PR (matrix-parity CI gate).

# 0011 Framework / layer / scene labels

Status: Accepted (2026-10-01).

Context: Operators need to know which UI framework owns pixels (hook
targeting, UIKit-vs-RN-vs-Flutter behavior) and which window a tree came from,
without a new channel or a guessing classifier that mislabels custom views.

Decision: Label-only annotations, nil-means-unknown, never a guess:
`InspectNode.framework` (inherited down subtrees; nil = indistinguishable
UIKit — `InspectRequest.swift:166-168`, `Inspector.swift:403-406`) and
`InspectNode.layer` (only when not a plain `CALayer`, else nil — payloads stay
small and diffs stay honest, `Inspector.swift:410-413`); per-class verdicts are
memoized (`Inspector.swift:244-274`). Responses name `frameworksDetected`,
`frameworkEvidence`, `rnArch`, and key-window `scene`
(`InspectRequest.swift:101-111`). Diffs gain `layer_flip` (both-nil old
timelines never fire — `SnapshotStore.swift:387-392`) and refuse cross-scene
pairs stated (`InspectTools.swift:305-311`); the manifest stores `scene` plus
informational `frameworks` (`SnapshotStore.swift:72-77`). Additive-only
evolution: every new field defaults nil (or historic ceilings for caps —
`SnapshotStore.swift:58-64`), so old timelines decode and pair.

Consequences: New frameworks are a classifier-table addition, never a schema
migration. `frameworks` stays informational (never a diff pairing key); `scene`
is a pairing key.

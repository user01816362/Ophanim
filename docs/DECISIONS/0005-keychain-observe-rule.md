# 0005 Keychain emulate-vs-observe rule

Status: Accepted (2026-09-30, cleanup ratification).

Context: Hosted apps expect the iOS keychain; sibling/agent contexts lack it.

Decision: Galgal emulates (`gg_SecItem*`); the agent observes. No agent-side
keychain writes.

Consequences: Keychain parity lives in the loader, not the engine. Changes
require loader + test-matrix updates together.

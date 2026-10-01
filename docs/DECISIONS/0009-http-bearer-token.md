# 0009 HTTP bearer token (MD-10 remainder)

Status: Accepted (2026-10-01).

Context: The loopback posture was already ported (opt-in `--port`, loopback
default + fallback, rebind refusal, no CORS). Any local process could still POST
write tools to the loopback server, and a non-loopback bind (`all`/specific)
had no auth at all.

Decision: `ophanim.mcp.token` (UserDefaults). Loopback never requires it
(same-machine boundary, current behavior). Non-loopback fails closed: first use
mints a UUID, persists it, and prints it to stderr; write tools
(`tools/call` outside the read-only sets) need `Authorization: Bearer <token>`
or get 401 + JSON-RPC error. Reads stay open everywhere; handshake methods
never pay.

Consequences: Non-loopback operators copy the token once from stderr. Stdio is
untouched (pipe-per-client, OS-mediated). GUI surface for the token: none —
UserDefaults key documented in code.

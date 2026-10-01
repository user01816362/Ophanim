# 0010 Push notifications (subscribe/unsubscribe_events)

Status: Accepted (2026-10-01).

Context: Polling `tail_events` in a hot loop wastes calls against the 120/min
per-tool budget; clients wanted push. But an MCP server here is a per-client
`--mcp` child whose only client-owned channel is its stdout pipe
(`StdioTransport.swift:10-13` — `notifierActive` is set only by `run()`; HTTP
and GUI processes refuse).

Decision: `subscribe_events`/`unsubscribe_events` are stdio-only
(`EventNotifier.swift:17-21` refuses elsewhere: "subscriptions need a stdio
--mcp child; over HTTP use tail_events waitMs"). Notifications carry
cursor+count only (`notifications/events/added`, `EventNotifier.swift:64-67`);
bodies still come via `tail_events` (`EventTools.swift:46-48`), so there is no
backlog to bound and capture can never block. One emitter thread per process at
1 s cadence over read-only scans; the last unsubscriber parks it and the next
subscribe restarts it (`EventNotifier.swift:51-58`); the cursor is client-held,
so reconnects re-poll or re-subscribe. HTTP stays poll-only via `waitMs` — no
SSE/HTTP-push path exists (no such code under `Core/MCP/`); push belongs to
the process that owns the stdout pipe (`EventNotifier.swift:9-10`).

Consequences: Stdio clients get cheap liveness; HTTP clients long-poll.
`threadParked` in the unsubscribe reply tells clients the emitter state.

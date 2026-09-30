# 0004 JS-policy evaluation point

Status: Accepted (2026-09-30, cleanup ratification).

Context: Rules need scriptable decisions without leaving the agent.

Decision: `OPInterceptor` evaluates `JSContext` policy on the consumer path
(never producer), behind `NSLock`, with `OPGlob` matching.

Consequences: Policy latency is off the hot path. JS errors degrade to
observe + log, never crash the target.

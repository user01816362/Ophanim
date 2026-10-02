# 0007 dryRun safety contract

Status: Accepted (2026-10-01).

Context: The OLD tree gave every destructive MCP tool preview-by-default
(`MCPArgs.isDryRun`, default true). The rebuild initially kept it on 3 inspect
tools only; ~16 destructive tools executed immediately with no `dryRun` schema
key, so LLM clients could not even discover preview.

Decision: Every destructive tool previews by default. `ToolRouter.isDryRun`
is the single helper (`(args["dryRun"] as? Bool) ?? true`); each mutating
handler branches before any mutation and each catalog entry advertises the
`dryRun` key. Exceptions, deliberate: pure setters (`set_config` field patch)
and gesture tools (`tap/swipe/set_text/inspect_pick` touch a live app; no
preview exists).

Note (2026-10-02, HEAD `267579b`): hook/rule writers refined the exception to
explicit-true preview — omitted `dryRun` WRITES (the historical agent contract;
flipping the default would silently turn existing callers' writes into
previews), `dryRun: true` previews counts/validation without persisting
(`HookTools.swift:5-9`, `RuleTools.swift:20-28,42-44`). `set_config` stays a
pure setter with no dryRun branch (field-level patch, unknown keys rejected).

Consequences: Adding a destructive tool means adding the branch + the schema
key in the same commit, or the catalog lies. `uninstall_app` keeps a shared
`uninstallTargets` inventory so preview and execution agree.

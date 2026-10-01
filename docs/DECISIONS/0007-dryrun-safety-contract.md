# 0007 dryRun safety contract

Status: Accepted (2026-10-01).

Context: The OLD tree gave every destructive MCP tool preview-by-default
(`MCPArgs.isDryRun`, default true). The rebuild initially kept it on 3 inspect
tools only; ~16 destructive tools executed immediately with no `dryRun` schema
key, so LLM clients could not even discover preview.

Decision: Every destructive tool previews by default. `ToolRouter.isDryRun`
is the single helper (`(args["dryRun"] as? Bool) ?? true`); each mutating
handler branches before any mutation and each catalog entry advertises the
`dryRun` key. Exceptions, deliberate: pure setters (`set_config`, hook/rule
writes are immediate full-replacements — stated in the description) and
gesture tools (`tap/swipe/set_text` touch a live app; no preview exists).

Consequences: Adding a destructive tool means adding the branch + the schema
key in the same commit, or the catalog lies. `uninstall_app` keeps a shared
`uninstallTargets` inventory so preview and execution agree.

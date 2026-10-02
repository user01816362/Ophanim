# Operator runbook

Short index for headless operation. `docs/MCP-GUIDE.md` owns every table below; this file only points at it.

## Session rules

Read `docs/MCP-GUIDE.md:24-36` first: `list_apps` for bundle IDs, `get_config` before mutating, preview before executing, 120 calls per minute per tool, `structuredContent` mirrored as text JSON.

## Dry-run contracts

Two families; never mix them (`docs/MCP-GUIDE.md:38-47`, contract in `docs/DECISIONS/0007-dryrun-safety-contract.md`):

- Most destructive tools default-true preview; pass `dryRun:false` to execute.
- `set_*_hooks`, `set_rules`, `apply_preset`: omitted writes, only `dryRun:true` previews.
- `set_config` and gestures (`tap_element`, `swipe`, `set_text`) have no preview.

## Live versus relaunch

See `docs/MCP-GUIDE.md:49-57`: rules, categories, sinks, and `bypassPinning` apply live; newly added hooks, injection strategy, `DYLD` libraries, Agent Mode on, and `install_app` output need a relaunch.

## Tool catalog

Read by domain in `docs/MCP-GUIDE.md:59-195`: apps, config, hooks and rules, tweaks, containers, sources, events and recon, inspect plus snapshots plus bookmarks. Hook and rule shapes plus the `ctx` script contract live in `docs/MCP-GUIDE.md:197-236`.

## Recipes and errors

- Recipes (first instrumentation, hook loop, rule loop, tweak iteration, UI investigation, container A/B, replay, uninstall): `docs/MCP-GUIDE.md:268-285`.
- Verbatim self-correcting errors: `docs/MCP-GUIDE.md:287-299`; liveness definition in `docs/CONTEXT.md:139-153`.
- Full Inspect protocol: `docs/INSPECT.md`.

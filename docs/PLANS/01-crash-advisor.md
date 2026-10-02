# PLAN-001: Post-mortem crash advisor (deferred)

Status: planned, not started. Do NOT implement until explicitly ordered.

## Verdict (locked)

- NO pre-launch "this app will fail" predictor. Failure modes are per-app and
  open-ended (keychain shapes, jailbreak checks, file probes, license servers);
  any heuristic list (bundle-ID blocklists, MSAL sniffing) rots and nags.
- YES post-mortem advisor later: app dies within N seconds of launch AND the
  crash/exception signature matches a known remediation → offer it with a
  one-click apply + relaunch. High signal, no prediction required.

## How it triggers (all pieces already exist)

1. Launch records start time (HostedApp launch path).
2. Process exits within the early-death window (proposed: 15 s) with non-zero status.
3. Correlate: OPCrashCorrelator crash record / uncaught-exception stderr pattern
   for that bundle id.
4. Match signature → remediation map; unknown signature → stay silent (log only).

## Remediation map (v1, extend by evidence only)

| Signature | Offer |
|---|---|
| Keychain-shape crash (`NSInvalidArgumentException`, MSAL/Office family; proven on Word 2.114.3: dies with `chainGuard:true`, lives with `false`) | "Disable ChainGuard for <App>? [Disable & Relaunch] [Keep]" → `set_config chainGuard=false` equivalent + relaunch |
| Invalid top-level seal (`codesign --verify` fails post-install) | "Re-sign <App>? [Re-sign & Relaunch]" → run the `sign()` seal path |
| Jailbreak-detection kill (detector catalog hit at exit) | Offer the matching `jailbreakBypasses` id, not "all" |

## Files to touch (verify paths at implementation time)

- Launch wrapper: record start/exit (HostedApp launch).
- Crash correlation: OPCrashCorrelator (existing) + early-death timer.
- Offer UI: alert with checkbox/shortcut parity per platform conventions; MUST be
  dismissible-per-app (never nag twice for a refused offer).
- Headless parity: MCP-visible refusal/acceptance state (operator via agent gets
  the same offer as data, not a modal).
- Per-app config writes go through SettingsStore (never direct plist edits).

## Batching

Own batch: one commit, one CI build. Needs device proof (kill Word-class app,
accept offer, confirm relaunch lives) before merge. GUI text via en strings.

## Non-goals

- No predictor, no blocklists, no MSAL sniffing, no auto-apply without consent.
- No new package-manager deps; no install-pipeline changes.

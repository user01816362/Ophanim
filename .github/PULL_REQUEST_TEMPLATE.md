# Pull request template

See `CONTRIBUTING.md` for the full rules.

## What and why

-

## Checklist

- [ ] Single concern, imperative subject line.
- [ ] Gates run in order: DRY greps, relocator self-test, `swiftc -parse` plus typecheck diff, `./build-ophanim.sh Release` plus bundle checks.
- [ ] `file:line` citations or `[unverified]` labels on high-stakes claims.
- [ ] Destructive tools ship the `dryRun` branch plus catalog key together.
- [ ] No workflow, `pbxproj` workaround, install-pipeline, or semantics change.
- [ ] Docs updated alongside code where required.

# Sample run — kubernetes-sigs/gwctl#110

Real artifacts from a real run, with machine-specific paths redacted to
`<workspace>` and `<home>`. Nothing here is illustrative or hand-written to
look good: `gate.json` and the logs under `evidence/` are the literal output of
`verify-all.sh`.

## What this example shows

**Verdict: `SUPPORT`** — issue #110 asks for a `-w`/`--watch` flag on
`gwctl get`. It is a *feature request*, not a defect, so the fix pipeline does
not apply and the run stopped at triage. See
[`triage-report.md`](triage-report.md).

That report is worth reading for one thing in particular: it **flags a gap in
its own vocabulary** rather than papering over it. The verdict set has no
`FEATURE` slot, so `SUPPORT` was used as the closest "not a defect, stop here"
verdict, and the report says so explicitly instead of quietly mislabelling the
issue.

## The gate result, and why `overall` is `fail`

[`gate.json`](gate.json) records three gates that genuinely ran and passed:

| Gate | Command | Result | Evidence |
|---|---|---|---|
| G0 build | `go build ./...` | pass (15s) | [`evidence/G0-build.log`](evidence/G0-build.log) |
| G3 unit + race | `go test -race -count=1 ./...` | pass (22s) | [`evidence/G3-unit-race.log`](evidence/G3-unit-race.log) |
| G4 diff hygiene | `lib/diff-hygiene.sh HEAD` | pass | [`evidence/G4-diff-hygiene.log`](evidence/G4-diff-hygiene.log) |

And yet:

```json
"missing_gates": ["G1", "G2", "G6", "G10"],
"overall": "fail"
```

**This is the system working correctly.** Only `--only G0,G3,G4` was requested,
so four applicable gates were never recorded — and an unrecorded gate counts as
a failure, not as a pass by omission. Three green gates out of seven is not a
verified change.

This is the single most important behaviour in the whole matrix: it is what
stops "the tests passed" from being reported as "the fix is proven". Compare
the honest failure here with what a summary of only the three green rows would
have implied.

## Reproducing it

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/verify-all.sh" \
  --state <state-dir> \
  --repo  <path-to-gwctl-clone> \
  --class cli-tool \
  --data  "${CLAUDE_PLUGIN_DATA}" \
  --only  G0,G3,G4
```

Drop `--only` to attempt the full `cli-tool` set. `--dry-run` prints the plan
without executing anything, which is the fastest way to see which gates a
change class actually demands.

## Note on the profile

`gwctl`'s `make build`, `make test`, and `make verify` all depend on a `deps`
target that re-resolves and re-vendors modules. The profile detector flags all
three as hazards and routes the gates to the plain `go` toolchain instead —
which is why the commands above are `go build ./...` rather than `make build`.
That routing is automatic and is recorded in the cached profile.

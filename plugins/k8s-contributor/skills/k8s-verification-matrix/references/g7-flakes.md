# G7 — flakes, in detail

A `kind/flake` issue has no single deterministic repro, so the pass criterion
is **statistical and two-sided**.

## Before the fix — reproduce it

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/repro-loop.sh --dir <repo> \
  --pkg ./test/integration/<area> --test '^TestFlaky$' \
  --mode reproduce --runs 20 --load --state <state-dir>
```

Runs the test N times (default 20) with `-race`, rotating `GOMAXPROCS` and
optionally under CPU load. **Require ≥1 failure in N** to consider the flake
reproduced. Scheduling pressure is what most timing flakes actually depend on,
which is why `--load` and the `GOMAXPROCS` rotation exist.

Exit codes: `0` reproduced, `3` not reproduced, `1` criterion not met.

### If it will not reproduce locally

**Do not guess a fix.** `repro-loop.sh` exits 3 and the correct output is
`insufficient-info`:

- attach the CI evidence from the issue — Testgrid, [go.k8s.io/triage], Prow
  logs, spyglass links;
- propose an **instrumentation-only PR** that would capture the missing state
  next time CI hits it, rather than a speculative fix;
- or widen the search first: raise `--runs`, add `--load`, widen
  `--gomaxprocs "1 2 4 8 16"`.

A fix for a flake you never reproduced cannot be verified, so it cannot pass.

[go.k8s.io/triage]: https://go.k8s.io/triage

## Root cause is mandatory

Each of these is a **blocker**-severity workaround unless the plan proves the
underlying race or ordering bug is actually gone:

- increasing a timeout
- adding a `time.Sleep`
- adding a retry around the failing operation
- marking the test `[Flaky]`
- loosening an assertion until it stops failing

Upstream policy backs this up: the project has a **zero-flake policy** and test
jobs must not auto-retry on failure
(`community/contributors/devel/sig-testing/flaky-tests.md`). Quarantining with
`[Flaky]` is a last resort that requires an issue in the current milestone,
labeled `priority/critical-urgent`, `lifecycle/frozen`, `kind/flake`, assigned
to the owning SIG — it is not a fix, and this system will not propose it as one.

## After the fix — confirm it

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/repro-loop.sh --dir <repo> \
  --pkg ./test/integration/<area> --test '^TestFlaky$' \
  --mode confirm --runs 50 --load --state <state-dir>
```

Require **≥50 consecutive clean runs** with `-race` (and under artificial load
where the flake was timing-related), *plus* the pre-fix reproduction recipe now
failing to reproduce.

Record **both** rates in `gate.json`. One-sided evidence is not a pass: 50 green
runs mean nothing if the pre-fix recipe never went red in the first place.

```jsonc
{ "id": "G7", "name": "flake-statistics", "status": "pass",
  "evidence": "evidence/repro-reproduce-<ts>/summary.json,evidence/repro-confirm-<ts>/summary.json",
  "reason": "pre-fix 3/20 failures; post-fix 0/50 with -race under load" }
```

## Writing the fix so it does not re-flake

From `flaky-tests.md`, the defensive-test guidance the reviewers check against:

- do not expect an asynchronous thing to happen immediately or after a fixed
  delay — poll and retry (`wait.PollUntilContextTimeout`), prefer informers and
  wait loops;
- do not use overly tight deadlines, and do not use unbounded ones either;
  non-`[Slow]` tests time out after 5 minutes;
- be specific enough that other tests running concurrently cannot perturb it —
  match on resource name *and* namespace;
- log enough for forensic debugging: what the test was doing, what specific
  check failed and how, and why a polling loop is still retrying.

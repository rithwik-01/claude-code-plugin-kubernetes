# G2 — the regression proof, in detail

The claim G2 makes is narrow and strong:

> This exact test **fails** on the code as it was, and **passes** on the code
> as it is now. Therefore the test detects the defect, and the defect is gone.

Both halves are required. A green test on the fixed tree proves nothing on its
own: it may be testing something the bug never touched.

## The mechanized procedure

```bash
STATE=.claude/k8s-contributor/state/<repo>/<issue>
PKG=./pkg/foo
TEST='^TestBarRejectsEmptyName$'

# 1. RED — remove the source fix, keep the test.
git stash push -- <source files only, NOT the test files>

${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh --state "$STATE" --id G2 --name red \
  --cmd "go test $PKG -run '$TEST' -race -count=1" --dir <repo> --expect-fail

# 2. restore
git stash pop

# 3. GREEN — same command, fix present.
${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh --state "$STATE" --id G2 --name green \
  --cmd "go test $PKG -run '$TEST' -race -count=1" --dir <repo>
```

`--expect-fail` inverts the pass condition: the command **must** exit non-zero.
If the red run succeeds, `run-gate.sh` records `status: fail` with the reason
*"the test passes without the fix, so it does not prove the regression"*.

## Which files go in the stash

Stash **only the source change**. If you stash the test too, the red run
compiles a tree with no test and `go test -run` exits 0 with "no tests to run"
— a false red that looks like a pass.

```bash
git diff --name-only            # inspect first
git stash push -- pkg/foo/bar.go pkg/foo/baz.go     # source only
```

Check the red log actually shows the assertion failing, not a build error in
unrelated code. A compile failure is a red run for the wrong reason.

## The worktree variant (safer, no stash juggling)

Preferred when the change is large or the working tree is precious. Nothing
here commits anything.

```bash
BASE=$(git merge-base HEAD origin/master)
git worktree add /tmp/g2-base "$BASE"

# copy ONLY the new/changed test file into the base tree
cp pkg/foo/bar_test.go /tmp/g2-base/pkg/foo/bar_test.go

( cd /tmp/g2-base && go test ./pkg/foo -run '^TestX$' -race -count=1 )  # MUST FAIL
go test ./pkg/foo -run '^TestX$' -race -count=1                          # MUST PASS

git worktree remove /tmp/g2-base --force
```

## Traps

| Trap | Why it fakes a pass | What to do |
|---|---|---|
| Test file stashed along with the source | `-run` matches nothing, `go test` exits 0 | stash source files only |
| Red run fails to **compile** | non-zero exit for the wrong reason | read the red log; require an assertion failure, not a build error |
| `-run` regex too loose | a different, already-passing test satisfies the run | anchor it: `-run '^TestExactName$'` |
| No `-count=1` | a cached result is replayed | always `-count=1` |
| Table-driven test where only a new case fails | the whole test fails before **and** after | run the subtest: `-run '^TestX$/^case_name$'` |
| Flake mistaken for red | the test failed for an unrelated timing reason | repeat the red run; for `kind/flake` work use G7, not G2 alone |
| `t.Skip()` on this platform | skipped tests exit 0 | check the log for `--- SKIP` |

## What `k8s-contributor:reviewer-tests` independently checks

It does not trust `evidence/G2-red.log`. It re-runs the red half itself and
additionally asks:

- Does the test fail for **the reason in the issue**, or for some other reason?
- Would this test still fail if the fix were reverted in a *different* way
  (i.e. is it pinned to the real invariant, or to an incidental detail)?
- Is the test deterministic — no `time.Sleep`, no wall-clock assumptions, no
  unbounded retries?
- Does it cover the negative case, not just the happy path?
- Could this test itself become a flake?

## Recording

Both halves land in `gate.json` under id `G2`, with evidence paths:

```jsonc
{ "id": "G2", "name": "regression-proof", "status": "pass",
  "evidence": "evidence/G2-red.log,evidence/G2-green.log", "exit_code": 0 }
```

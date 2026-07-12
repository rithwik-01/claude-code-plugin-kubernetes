---
name: k8s-fix
description: Implement an approved Kubernetes fix - plan loop with an adversarial plan reviewer, red-first test then minimal change on a new branch, six parallel read-only reviewers, synthesis, and an evidence-based verifier gate, both loops bounded at three rounds. Use only after /k8s-triage returned REAL and the user explicitly approved proceeding. Never commits, never pushes, never posts.
argument-hint: <github-issue-url | state-dir>
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/verify-all.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/repro-loop.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/detect-profile.sh:*), Bash(go test:*), Bash(go build:*), Bash(go vet:*), Bash(make test:*), Bash(make verify:*), Bash(git diff:*), Bash(git status:*), Bash(git stash:*), Bash(git worktree:*), Bash(git checkout:*), Bash(git branch:*), Bash(git log:*), Bash(git rev-parse:*), Read, Grep, Glob, Write, Edit
---

# /k8s-fix — approved verdict → verified working tree

Target: **$ARGUMENTS**

## Current state

```!
cd "${CLAUDE_PROJECT_DIR:-$PWD}" && echo "runs in progress:" && (ls -1d .claude/k8s-contributor/state/*/*/ 2>/dev/null | sed 's/^/  /' || echo "  (none)")
```

---

## Precondition — check this first

> **This skill requires that `/k8s-triage` returned `REAL` *and* the user
> explicitly approved proceeding, in words, in this conversation.**
>
> If `triage-report.md` is missing, the verdict is not `REAL`, or you cannot
> point at the user's approval, **stop and ask**. Do not infer approval from
> the fact that you were invoked.

Load: `triage-report.md`, `issue.json`, the profile, and `loop.json` if this is
a resumed run.

## Resuming

`loop.json` in the state dir holds `phase`, `plan_loop.round`, and
`review_loop.round`. On resume, read it, say which phase and round you are
picking up at, and continue from there. Update it at every phase transition —
that is what makes a later session able to continue this work.

---

## Phase 2 — Plan loop (max 3 rounds)

The **resident thread** writes `plan.md`, following the charter in
`${CLAUDE_PLUGIN_ROOT}/agents/planner.md`. All nine sections are mandatory:

1. Root cause (at `file:line`, causal chain; **two sentences or you do not have
   it**) · 2. Options considered (≥2; prove the choice is a *fix*, not a
   workaround) · 3. Blast radius · 4. API and compatibility impact ·
5. Codebase-pattern anchor (`file:line`) · 6. Test plan (including **the exact
   test that will fail before the fix**) · 7. Verification plan (the gate set)
   · 8. Release note (or `NONE` with a reason) · 9. Rollback / risk

Then run `k8s-contributor:plan-reviewer` (ephemeral, adversarial). Loop until `pass`, **max 3
rounds**. On exhaustion, stop and write a human-escalation report: what is
unresolved, and what decision the human must make.

## Phase 3 — Worker (resident)

1. **Branch.** `fix/<issue>-<slug>`, or `flake/<issue>-<slug>`. **Never work on
   `master`/`main`.**

2. **Red first.** Write or extend the test **before** the source change, run
   it, and capture the failure to `evidence/red.log`.

   > **If the test passes before the fix, the test is wrong — go back.**

3. **Implement the minimal correct change** per the plan. Match the
   surrounding style exactly: receiver naming, error wrapping
   (`fmt.Errorf("…: %w", err)`), the `klog` structured/contextual style that
   package already uses, context propagation, metric naming, and table-driven
   tests built from the package's existing helpers — `k8s.io/kubernetes/test/utils`,
   `ktesting`, `wait.PollUntilContextTimeout`, `apitesting`, `fake` clients,
   whatever it already uses. See the `k8s-codebase-patterns` skill.

4. **Zero new third-party dependencies.** No `go get`, no `go.mod`/`go.sum`/
   `vendor/` edits. Enforced by `guard-deps.sh`; a dependency change is a
   `blocker`.

5. Capture `evidence/green.log` after the fix.

6. **Regenerate, never hand-edit,** generated files —
   `hack/update-codegen.sh`, `hack/update-*.sh`, `make update`.

7. **Do not commit.** Leave the change in the working tree. Write the proposed
   commit breakdown to `artifacts/proposed-commits.md`: per commit, the file
   list, the full message in the repo's history style, and the exact
   `git add … && git commit -m …` command. Then **stop and ask**.

   Only run those commands if the user replies with explicit approval **in that
   same exchange**. Never amend, rebase, `git reset --hard`, or otherwise
   rewrite history; never push.

   > Commit-message trap: **no GitHub keywords** (`fix(es|ed)`, `close(s|d)`,
   > `resolve(s|d)`) and no `@mentions` in a commit message — they trigger
   > `do-not-merge/invalid-commit-message`. `Fixes #<n>` goes in the **PR
   > description** only.

8. **Protecting the tree mid-run** (e.g. around the red/green check): use
   `git stash`, `git worktree`, or a patch file under the state dir — **never a
   commit**.

## Phase 4 — Review fan-out

Launch **six reviewers in parallel** (the concurrency ceiling for this fan-out
is 6), each given the diff (`git diff <base>...HEAD`), `plan.md`,
`triage-report.md`, and the profile:

`k8s-contributor:reviewer-correctness` · `k8s-contributor:reviewer-conventions` · `k8s-contributor:reviewer-tests` ·
`k8s-contributor:reviewer-compat` · `k8s-contributor:reviewer-perf-security` · `k8s-contributor:reviewer-maintainability`

All are read-only. Each returns the JSON contract.

## Phase 5 — Synthesize

Run `k8s-contributor:synthesizer` (phase: review) → `review-synthesis.md` plus one ordered
action list. It deduplicates, resolves contradictions (saying which side it
took and why), ranks by severity then cost-to-fix, and **adds no findings of
its own**.

## Phase 6 — Pass? gate

Run `k8s-contributor:verifier`. It executes `${CLAUDE_PLUGIN_ROOT}/scripts/verify-all.sh` and reads
`gate.json`. **The gate is decided by artifacts on disk.** PASS requires
*both*:

- every applicable gate `pass` in `gate.json` with a non-empty evidence path
  (or `not-applicable` / `deferred-to-ci` with a stated reason), **and**
- zero `blocker` and zero `major` findings in `review-synthesis.md`.

Anything else is FAIL → the ordered action list goes back to Phase 3.
**Max 3 review rounds**, then escalate.

> Never silently downgrade a blocker to make the gate pass.

## Phase 7 — Final packaging

Produce in the state dir and print the paths:

- `report.md` — one page: verdict, root cause, the fix in three sentences, the
  evidence table (gate → command → result → log path), residual risks,
  alternatives rejected and why, what CI will still need to prove.
- `pr-description.md` — **the repo's actual PR template**, read from disk
  (`profile.pr_template`), filled in. For `kubernetes/kubernetes` that is
  `What type of PR is this?` with `/kind …`; `What this PR does / why we need
  it`; `Which issue(s) this PR is related to:` with `Fixes #<n>`
  (**omit `Fixes` for `kind/flake` and `kind/failing-test`** — the template
  says so); `Special notes for your reviewer`; a ```` ```release-note ````
  block (or `NONE`); `Additional documentation`; plus `/sig <sig>` and
  `/cc @<owners>`.
- `issue-comment.md` — optional draft comment.
- `proposed-commits.md` — the commit plan from Phase 3, **unexecuted**.

## The rule that outranks everything above

> **Never** run `git commit`, `git push`, `gh pr create`, `gh pr comment`,
> `gh issue comment`, `gh issue close`, or anything that posts a Prow command.
>
> Every artifact here is a **draft for the user's review**, not something to
> send. End the run by printing the file paths plus a clearly-labelled
> **"commands you can run yourself"** block — then stop. Do not offer to run
> them as the next step; wait to be asked.

## Reusable workflow (optional)

If your Claude Code build supports dynamic workflows, you can codify this
orchestration after a successful run: `/workflows` → select the run → press
`s`. It saves into **your** project at `.claude/workflows/`, not into the
plugin — a plugin's directory is a cache that is replaced on every update.
Worth doing for the review fan-out and the bounded feedback loop specifically:
same shape every time, needs a real loop, must not stop early.

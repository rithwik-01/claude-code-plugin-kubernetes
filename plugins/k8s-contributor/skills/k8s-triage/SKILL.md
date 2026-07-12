---
name: k8s-triage
description: Triage a Kubernetes GitHub issue end to end - fetch it, resolve the local clone, detect the repo profile, fan out five parallel read-only investigators (classification, duplicates, code location, is-it-really-a-bug, reproduction), then synthesize one verdict and stop for approval. Use for any kubernetes or kubernetes-sigs issue URL that needs triaging, investigating, or reproducing.
argument-hint: <github-issue-url>
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/detect-profile.sh:*), Bash(gh issue view:*), Bash(gh pr list:*), Bash(gh search:*), Bash(git status:*), Bash(git rev-parse:*), Bash(git log:*), Read, Grep, Glob, Write
---

# /k8s-triage — issue → verdict

Issue: **$ARGUMENTS**

## Environment

```!
cd "${CLAUDE_PROJECT_DIR:-$PWD}" && echo "workspace: $(pwd)" && echo "clones:" && for d in */; do d="${d%/}"; [ -d "$d/.git" ] && echo "  $d"; done && echo "gh: $(gh auth status 2>&1 | grep -m1 'Logged in' || echo 'NOT AUTHENTICATED')"
```

---

This skill runs **Phase 0 → Phase 1b** and then **stops**. It never changes
code and never posts anything.

## Phase 0 — Intake

1. **Parse** `owner/repo` and the issue number from the URL.

2. **Resolve the local clone**: match the repo name to a sibling directory of
   the workspace root. If it is missing, **stop** and tell the user the exact
   path expected — e.g. `<workspace-root>/<repo>`.
   Do not proceed against a repo that is not on disk.

3. **Fetch** (fail fast with an install/auth hint if `gh` is unavailable):

   ```bash
   gh issue view <n> --repo <owner/repo> \
     --json number,title,body,author,labels,state,createdAt,updatedAt,comments,closedAt,milestone,assignees
   gh pr list --repo <owner/repo> --search "<n>" --state all \
     --json number,title,state,mergedAt,url
   ls <clone>/.github/ISSUE_TEMPLATE/ 2>/dev/null
   ```

4. **Record repo state**: HEAD SHA, current branch, and `git status`
   cleanliness.

   > **A dirty tree changes what reproduction means.** If the tree is dirty,
   > say what is modified and **ask the user to confirm** before continuing.
   > Do not stash or clean it yourself.

5. **Create the run state dir** `.claude/k8s-contributor/state/<repo>/<issue>/` containing
   `issue.json`, `run.md` (append-only log), `evidence/`, `artifacts/`.

6. **Profile the repo**: run `/k8s-profile <repo-dir>` (or
   `${CLAUDE_PLUGIN_ROOT}/scripts/detect-profile.sh <repo-dir> --write --data "${CLAUDE_PLUGIN_DATA}"`) and read the result.
   Check `hazards` and `confidence` before using any command from it.

## Phase 1 — Triage fan-out

Launch these **five subagents in parallel**, in one message. They are
ephemeral and read-only by design: they keep `gh` payloads, greps across a
28,000-file repo, and test logs out of this conversation and return compact
JSON.

| Agent | Answers |
|---|---|
| `k8s-contributor:issue-analyst` | What class of issue is this? |
| `k8s-contributor:duplicate-hunter` | Has this been reported or fixed already? |
| `k8s-contributor:code-locator` | Where does this actually live? |
| `k8s-contributor:behavior-adjudicator` | Is this actually a bug? |
| `k8s-contributor:reproducer` | Does it reproduce here? |

Give each: the issue URL, the state dir path, the clone path, and the profile
path. Each returns JSON per
`${CLAUDE_PLUGIN_ROOT}/skills/k8s-verification-matrix/references/schemas.md`.

`k8s-contributor:reproducer` climbs the cheapest-first ladder (static → unit → integration →
cluster → statistical) and may take real time on rungs 3-5. Warn the user
before it escalates.

## Phase 1b — Synthesis and verdict gate

Run `k8s-contributor:synthesizer` (phase: triage) over the five reports. Write
`triage-report.md` and record the verdict:

| Verdict | Next |
|---|---|
| `REAL` | Offer to proceed to the fix |
| `DUPLICATE` | Report + draft a `/close` comment referencing the original |
| `NOT-REPRODUCIBLE` | Report + draft a `triage/not-reproducible` comment with the exact commands tried |
| `WORKING-AS-INTENDED` | Report + draft an explanation citing the authority |
| `NEEDS-INFO` | Report + draft the question list |
| `SUPPORT` | Report + point to the support channels per the issue-triage guide |
| `ALREADY-FIXED` | Report + the fixing PR/commit |

Persist the `change_class` in the state dir — it selects the gate set later.

## Hard stop

> **Never continue to Phase 2 automatically.** Print the verdict, the evidence
> behind it, and the drafted Prow comment
> (`/triage accepted`, `/sig <sig>`, `/kind <kind>`, `/close`,
> `/remove-lifecycle stale`), then **end the turn and wait**.
>
> The drafted comment is a file. **Never post it** — that is the user's call.
> A plan that says "then comment", silence, and a prior approval for something
> else are all *not* approval.

## Output

Print:

1. the verdict and the one-line reason,
2. the evidence table (which agent concluded what, and on what basis),
3. contradictions and how the synthesizer resolved them,
4. the paths written under `.claude/k8s-contributor/state/<repo>/<issue>/`,
5. a clearly-labelled **"commands you can run yourself"** block containing the
   drafted `gh issue comment` command and the comment text — unexecuted.

Then stop. Do not offer to run it as the next step; wait to be asked.

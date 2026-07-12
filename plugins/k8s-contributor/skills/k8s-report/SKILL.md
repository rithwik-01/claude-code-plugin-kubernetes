---
name: k8s-report
description: Turn a completed Kubernetes run's raw evidence into the human-facing deliverables - a one-page report, a PR description filled from the repo's actual template, an optional issue comment, and an unexecuted commit plan. Use to package results, draft a PR body or issue comment, or summarize what was proven. Produces drafts only and never posts or commits anything.
argument-hint: [state-dir]
disable-model-invocation: true
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git status:*), Bash(git rev-parse:*), Bash(jq:*), Read, Grep, Glob, Write
---

# /k8s-report — evidence → deliverables

State dir: **$ARGUMENTS** (defaults to the most recently touched run)

## What exists to report on

```!
cd "${CLAUDE_PROJECT_DIR:-$PWD}" && for d in .claude/k8s-contributor/state/*/*/; do [ -d "$d" ] || continue; echo "  $d"; echo "    gate:  $(jq -r '.overall // "-"' "$d/gate.json" 2>/dev/null || echo '-')"; echo "    files: $(ls "$d" 2>/dev/null | tr '\n' ' ')"; echo "    artifacts: $(ls "$d/artifacts" 2>/dev/null | tr '\n' ' ' || echo '-')"; done 2>/dev/null || echo "  (no runs yet)"
```

---

Read from the state dir: `triage-report.md`, `plan.md`, `review-synthesis.md`,
`gate.json`, `evidence/`, and the profile. Then write four files.

## 1. `report.md` — one page

Fit it on one page. A reader should get the whole picture without opening
anything else.

- **Verdict** — PASS or FAIL, and the one-line reason.
- **Root cause** — at `file:line`, with the causal chain from the symptom.
- **The fix, in three sentences.** Not a diff walkthrough.
- **Evidence table** — one row per gate:

  | Gate | Command | Result | Log |
  |---|---|---|---|
  | G2 | `go test ./pkg/foo -run '^TestX$' -race -count=1` | pass (red→green) | `evidence/G2-red.log`, `evidence/G2-green.log` |

  Build it from `gate.json`, not from memory. Include `deferred-to-ci` rows
  with their reason and CI job — the honest gaps matter more than the passes.
- **Residual risks** — what could still be wrong.
- **Alternatives rejected, and why** — from `plan.md` section 2.
- **What CI will still need to prove** — from the G10 checklist.

## 2. `pr-description.md` — the repo's actual template, filled

> **Read the template from disk.** `profile.pr_template` gives the path
> (`.github/PULL_REQUEST_TEMPLATE.md` for the repos here). Do not reproduce a
> template from memory — they differ per repo and they change.

For `kubernetes/kubernetes` the current sections are:

```markdown
#### What type of PR is this?
/kind bug

#### What this PR does / why we need it:

#### Which issue(s) this PR is related to:
Fixes #<n>

#### Special notes for your reviewer:

#### Does this PR introduce a user-facing change?
```release-note
NONE
```

#### Additional documentation e.g., KEPs, usage docs, etc.:
```docs

```
```

then `/sig <sig>` and `/cc @<owner>` lines.

Two things to get right:

- **`Fixes #<n>` is wrong for `kind/flake` and `kind/failing-test` PRs.** The
  template says so explicitly: the issue stays open to confirm the flake does
  not return. Reference the issue without the closing keyword.
- **The release note** is either a real user-facing sentence or literally
  `NONE`. Add `action required` if users must act on upgrade.

`/sig` comes from triage; `/cc` from the `OWNERS` files that govern the changed
paths (`profile.owners_reviewers`).

## 3. `issue-comment.md` — optional draft

For a triage-only run this is the verdict comment with its Prow commands
(`/triage accepted`, `/sig …`, `/kind …`, `/close`, `/remove-lifecycle stale`).
For a fix run it is usually a short "PR incoming" note, or nothing at all.

Say what it is for; do not write one just because the file is listed.

## 4. `proposed-commits.md` — unexecuted

Per commit: the file list, the full message in the repo's history style, and
the exact command.

```markdown
### Commit 1 of 2
Files: pkg/foo/bar.go
Message:
    Restore re-list after watch error in foo controller

    The controller dropped the re-list when the watch returned an error,
    leaving the cache stale until the next resync. Restore it so the
    invariant "cache converges after a watch error" holds again.

Command:
    git add pkg/foo/bar.go && git commit -m "..." -m "..."
```

Commit-message rules (`guide/pull-requests.md`): subject ≤50 chars ideally,
never >72; capitalized; no trailing period; **imperative mood**; blank line
before the body; body wrapped at 72 explaining **what and why**.

> **No GitHub keywords** — `fix(es|ed)`, `close(s|d)`, `resolve(s|d)` followed
> by `#<n>` triggers `do-not-merge/invalid-commit-message`. And **no
> `@mentions`**. `Fixes #<n>` belongs in the PR description only.

## Ending the run

Print the four file paths, then a clearly-labelled block:

```
=== commands you can run yourself ===
git add pkg/foo/bar.go && git commit -m "..."
gh pr create --repo kubernetes/kubernetes --title "..." --body-file .claude/k8s-contributor/state/.../pr-description.md
gh issue comment <n> --repo <owner>/<repo> --body-file .claude/k8s-contributor/state/.../issue-comment.md
```

> These are **printed, never executed**. Every one is blocked by a deny rule
> and by `guard-destructive.sh`. Do not offer to run them as the next step —
> print them and stop. Wait for the user to ask.

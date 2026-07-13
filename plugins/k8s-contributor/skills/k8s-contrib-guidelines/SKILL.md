---
name: k8s-contrib-guidelines
description: Kubernetes contributor process read from the kubernetes/community docs on disk (a local clone if you have one, otherwise a fetched-and-cached copy) - issue triage verdicts and Prow commands, PR conventions and release notes, coding and testing conventions, API change rules, logging and metrics conventions, OWNERS, and cherry-pick eligibility. Load before triaging an issue, writing a plan, reviewing a diff, or drafting a PR description.
user-invocable: false
---

# Kubernetes contributor process

**Source of truth is the kubernetes/community docs on disk**, not memory.
Resolve their location first, then read the file before citing it, and cite
`path#section` in every finding.

## Step 0 — resolve the docs (do this before citing anything)

```bash
COMMUNITY=$("${CLAUDE_PLUGIN_ROOT}/scripts/resolve-community.sh" --data "${CLAUDE_PLUGIN_DATA}")
echo "$COMMUNITY"        # -> <somewhere>/contributors
```

The script tries, in order:

1. the `community_docs_path` plugin option, if you set one at enable time;
2. a `community/` clone beside your workspace or the current repo, or
   `$GOPATH/src/k8s.io/community`;
3. a cached copy under `${CLAUDE_PLUGIN_DATA}/community-docs/`, refetched when
   it is more than 30 days old;
4. a fresh sparse fetch of `https://github.com/kubernetes/community` into that
   cache (a few seconds, ~20 MB).

**Exit 4 means unresolved.** If that happens, do not fall back on remembered
conventions — triage verdicts, Prow commands, PR templates and cherry-pick
rules all drift, and a confidently-wrong citation is worse than an admitted
gap. Say in your output that the guidelines could not be verified, cite the
upstream URL instead of a section you did not read, and tell the user how to
fix it (the script prints the three options).

Whatever resolves, it is a snapshot. If a claim matters and the copy looks
stale relative to upstream, prefer the copy on disk — it is what the user reads
— and note the drift explicitly.

All paths below are relative to the resolved `$COMMUNITY` directory.

## Where things are

| Topic | Path under `$COMMUNITY/` |
|---|---|
| Development setup, build/test | `devel/development.md` |
| Testing guide | `devel/sig-testing/testing.md` |
| Integration tests | `devel/sig-testing/integration-tests.md` |
| E2E tests | `devel/sig-testing/e2e-tests.md`, `writing-good-e2e-tests.md` |
| **Node e2e** | `devel/sig-node/e2e-node-tests.md` — note: under `sig-node/`, **not** `sig-testing/` |
| Flaky tests | `devel/sig-testing/flaky-tests.md` |
| API conventions | `devel/sig-architecture/api-conventions.md` |
| API changes | `devel/sig-architecture/api_changes.md` |
| Feature gates | `devel/sig-architecture/feature-gates.md` |
| Logging | `devel/sig-instrumentation/logging.md` |
| Metrics | `devel/sig-instrumentation/metric-instrumentation.md`, `metric-stability.md` |
| Cherry-picks | `devel/sig-release/cherry-picks.md` |
| Contributor guide index | `guide/README.md` |
| First contribution | `guide/first-contribution.md` |
| Git workflow | `guide/github-workflow.md` |
| Pull requests | `guide/pull-requests.md` |
| Coding conventions | `guide/coding-conventions.md` |
| Issue triage | `guide/issue-triage.md` |
| OWNERS | `guide/owners.md` |

Upstream mirrors, for drift checks only:
<https://github.com/kubernetes/community/tree/main/contributors/devel> and
<https://www.kubernetes.dev/docs/guide/issue-triage/>.

## Issue triage — the decision the user is asked to approve

From `guide/issue-triage.md`. New issues get `needs-triage` automatically;
`/triage accepted` removes it and adds `triage/accepted`.

| Situation | Label / command | This system's verdict |
|---|---|---|
| Reproduced, real defect | `/triage accepted`, `/sig <sig>`, `/kind bug` | `REAL` |
| Same root cause as an existing issue | reference the original, `/close` | `DUPLICATE` |
| Steps exist, do not reproduce at HEAD | contact reporter; close if agreed | `NOT-REPRODUCIBLE` |
| Behavior matches spec | explain, cite the authority | `WORKING-AS-INTENDED` |
| Cannot decide without the reporter | `/triage needs-information` | `NEEDS-INFO` |
| Usage question, not a defect | `/kind support`, point to support channels | `SUPPORT` |
| Already fixed on master, unreleased | link the fixing PR | `ALREADY-FIXED` |

Priorities: `priority/critical-urgent` (drop everything: user-visible bugs in
core features, broken builds, critical security), `priority/important-soon`,
`priority/important-longterm`, `priority/backlog`,
`priority/awaiting-more-evidence`.

Staleness: 90 days of inactivity → `lifecycle/stale` from the triage robot;
`/remove-lifecycle stale` clears it, `/lifecycle frozen` prevents it.

No response within 20 days on a needs-information issue → close with a comment.

Support channels: <https://kubernetes.io/docs/home/>,
<https://discuss.kubernetes.io>, <https://kubernetes.slack.com>.

> **This system drafts Prow comments. It never posts them.** Every `/triage`,
> `/close`, `/sig`, `/kind`, `/lgtm`, `/approve`, `/retest` is a draft in
> `issue-comment.md` for the user to send. A `PreToolUse` hook blocks any
> command carrying a Prow slash-command.

## Coding conventions

From `guide/coding-conventions.md` — read it, it is only ~60 lines.

- Go: [Go Code Review Comments], [Effective Go], avoid the known Go landmines.
- **Naming**: consider the package name and avoid redundancy —
  `storage.Interface`, not `storage.StorageInterface`. No uppercase,
  underscores, or dashes in package names. `pkg/controllers/autoscaler/foo.go`
  is `package autoscaler`, not `package autoscalercontroller`. The `package`
  line should match its directory unless there is a good reason.
- **Locks** are called `lock` and are never embedded: `lock sync.Mutex`. With
  several, name each: `stateLock`, `mapLock`.
- Command-line flags use dashes, not underscores.
- Comment your code; if a reviewer asks why it is the way it is, that is a sign
  a comment was missing.
- All filenames lowercase. Go files and dirs use underscores; doc files use
  dashes.
- Avoid package sprawl and "util" packages — name the function's domain
  (`wait.Poll`, not `util.Poll`).

[Go Code Review Comments]: https://go.dev/wiki/CodeReviewComments
[Effective Go]: https://golang.org/doc/effective_go.html

## Testing conventions

- All new packages and most new significant functionality need unit tests.
- **Table-driven tests are preferred** for multiple scenarios/inputs.
- Significant features need integration (`test/integration`) and/or e2e
  (`test/e2e`) tests — including new `kubectl` commands.
- Unit tests **must pass on macOS and Windows**. Linux-specific tests must be
  skipped on Windows (preferred when running Linux-only commands) or compiled
  out (required when the code will not build on Windows).
- **Do not expect an asynchronous thing to happen immediately.** Never sleep a
  second and assert a pod is running — wait and retry.
- Avoid Docker Hub; use the Google Cloud Artifact Registry.
- Integration tests should only touch local resources (etcd, localhost
  services). Each test creates its own server and config.

Integration test invocation (`devel/sig-testing/integration-tests.md`):

```bash
hack/install-etcd.sh                          # installs into ./third_party/etcd
export PATH=$PATH:$(pwd)/third_party/etcd
make test-integration WHAT=./test/integration/pods GOFLAGS="-v" \
     KUBE_TEST_ARGS="-run ^TestPodUpdateActiveDeadlineSeconds$"
```

`TEST_ETCD_DIR` overrides where internally started etcd instances write data.

## Pull requests

Read the repo's **actual** PR template — do not reproduce one from memory.
For `kubernetes/kubernetes` it is `.github/PULL_REQUEST_TEMPLATE.md`, whose
current sections are:

- `#### What type of PR is this?` — `/kind bug`, plus optional `/kind
  api-change`, `/kind deprecation`, `/kind failing-test`, `/kind flake`,
  `/kind regression`
- `#### What this PR does / why we need it:`
- `#### Which issue(s) this PR is related to:` — `Fixes #<n>`.
  **Do not use "Fixes" when the PR is `kind/failing-test` or `kind/flake`.**
- `#### Special notes for your reviewer:`
- `#### Does this PR introduce a user-facing change?` — a ```` ```release-note ````
  fenced block, or `NONE`
- `#### Additional documentation …` — a ```` ```docs ```` fenced block

Then `/sig <sig>` and `/cc @<owners>` lines.

More detail: [references/pr-and-review.md](references/pr-and-review.md).

## Cherry-picks

From `devel/sig-release/cherry-picks.md`. Only these are backported:

- security fixes (but not dependency bumps that merely silence a scanner)
- regression fixes (**not** if the regression only occurs with an
  off-by-default alpha feature enabled)
- critical bug fixes: data loss, memory corruption, panic, crash, hang (same
  alpha-feature exclusion)
- prerequisites for critical dependency updates
- **test-only changes that stabilize failing/flaky tests on release branches**

Cherry-pick to *every* supported release branch, newest first, via
`hack/cherry_pick_pull.sh upstream/release-X.Y <PR>`. Explain any branch you skip.

## More references

- [references/pr-and-review.md](references/pr-and-review.md) — PR template,
  review expectations, release notes, OWNERS
- [references/testing-tiers.md](references/testing-tiers.md) — which tier
  proves what, and the flake policy
- [references/api-and-compat.md](references/api-and-compat.md) — API changes,
  feature gates, version skew, logging and metrics conventions

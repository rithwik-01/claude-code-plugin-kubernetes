# Quickstart

## Install

```bash
claude plugin marketplace add rithwik-01/claude-code-plugin-kubernetes
claude plugin install k8s-contributor@claude-code-plugin-kubernetes
claude plugin enable  k8s-contributor@claude-code-plugin-kubernetes
```

The plugin ships `defaultEnabled: false`, so it installs disabled and you opt
in. Then, inside Claude Code, from the directory holding your clones:

```
/k8s-setup
```

## What you need first

`/k8s-setup` checks all of this and prints install commands for anything
missing. It installs nothing itself.

| Tool | Needed for |
|---|---|
| `gh`, authenticated | fetching issues, duplicate search |
| `go` | every build and test gate |
| `git` | diffs, branches, fetching the contributor docs |
| `jq` | `gate.json`, hook payload parsing |
| `docker` + `kind` | the G6 cluster gate only |
| `etcd` | the G5 integration gate only |

You also need at least one `kubernetes/*` or `kubernetes-sigs/*` clone already
on disk. The plugin never clones anything for you.

A workspace holding several clones side by side works best:

```
my-k8s-work/
├── kubernetes/          # a clone
├── gwctl/               # another
└── community/           # optional; auto-detected as the docs source
```

## A normal run

```
/k8s-triage https://github.com/kubernetes/kubernetes/issues/12345
```

Five investigators run in parallel, a synthesizer merges them, and you get a
verdict plus the evidence behind it. **Then it stops.** It does not proceed to
a fix, and it does not post the Prow comment it drafted for you.

If the verdict is `REAL` and you want to continue, say so in words:

```
/k8s-fix    https://github.com/kubernetes/kubernetes/issues/12345
/k8s-verify .claude/k8s-contributor/state/kubernetes/12345
/k8s-report .claude/k8s-contributor/state/kubernetes/12345
```

`/k8s-fix` plans, writes a failing test **first**, implements the minimal
change, runs six reviewers in parallel, and gates on artifacts. It leaves the
change in your working tree, uncommitted, with the proposed commits written to
`artifacts/proposed-commits.md` for you to run.

## Where things end up

```
<your-workspace>/.claude/k8s-contributor/state/<repo>/<issue>/
├── issue.json            triage-report.md    plan.md
├── review-synthesis.md   gate.json           loop.json
├── gates/                one JSON per gate
├── evidence/             every log an assertion points at
└── artifacts/            report.md, pr-description.md,
                          issue-comment.md, proposed-commits.md
```

Add this to your `.gitignore`:

```
.claude/k8s-contributor/state/
```

Profiles, fetched docs, and agent memory live in the plugin's data directory
instead, so they survive plugin updates.

## Resuming

Runs are resumable. `loop.json` holds the phase and both loop counters:

```
/k8s-fix .claude/k8s-contributor/state/<repo>/<issue>
```

It announces the phase and round it is picking up at, then continues.

## The one behavioral note

**This plugin never commits, never comments, and never pushes.** Every such
action is written to a file and printed for you to run. That is enforced by a
`PreToolUse` hook that ships with the plugin, needs no configuration, and has
no bypass — see [architecture.md](architecture.md#the-approval-guarantee).

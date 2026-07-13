---
name: k8s-setup
description: First-run setup for the k8s-contributor plugin - discover your kubernetes clones, check prerequisites, cache a build profile per repo, resolve the contributor docs, and offer to install the recommended permission deny rules. Use once after installing the plugin, or any time your workspace or tooling changed. Safe to re-run.
argument-hint: [workspace-dir]
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/check-prereqs.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/detect-profile.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-community.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/merge-deny.sh:*), Bash(ls:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(gh auth status:*), Read, Grep, Glob
---

# /k8s-setup — make the plugin usable on this machine

Workspace: **$ARGUMENTS** (defaults to the current project directory)

## What is here right now

```!
cd "${CLAUDE_PROJECT_DIR:-$PWD}" && echo "workspace: $(pwd)" && echo && echo "git clones found:" && found=0 && for d in */; do d="${d%/}"; [ -d "$d/.git" ] || continue; found=1; url=$( (cd "$d" && git remote get-url origin) 2>/dev/null || echo "(no origin)"); printf '  %-18s %s\n' "$d" "$url"; done; [ "$found" = 0 ] && echo "  (none -- is this the directory holding your clones?)"; echo; echo "plugin data dir: ${CLAUDE_PLUGIN_DATA}"
```

---

This skill is **idempotent**: re-running it re-checks everything and changes
nothing that is already correct. It **installs no software** and **writes no
configuration without asking you first**.

Work through the six steps in order and print the summary at the end.

> When you need git inside another clone, use `(cd <repo> && git ...)`, not the
> `git -C` flag. This plugin's own guard blocks `git -C`, because
> redirecting git at a different checkout is the documented way around
> path-based rules.

## Step 1 — Identify the workspace and its repos

From the listing above, keep the clones whose `origin` points at
`kubernetes/*` or `kubernetes-sigs/*`. Report the others as "present, not a
Kubernetes repo — ignored".

If **no** Kubernetes clone was found, stop and say so plainly: this plugin
operates on clones that already exist on disk. Tell the user the workspace it
looked in, and that they can either `cd` to the right directory, pass one as
`/k8s-setup <dir>`, or set the `workspace_root` plugin option. Do not clone
anything yourself.

## Step 2 — Check prerequisites

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/check-prereqs.sh" <one-repo-dir>
```

It reports each tool as present or missing, with the install command and which
gate the missing tool blocks, plus `gh` auth state and your Go version against
that repo's `go.mod` / `.go-version`.

> **Install nothing.** Print the table. If something required is missing, say
> which gates are unavailable until it is installed, and let the user decide.
> `etcd` is the usual gap: offer `hack/install-etcd.sh` **as a command they can
> run**, do not run it.

## Step 3 — Profile each repo

For every Kubernetes clone found:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/detect-profile.sh" <repo-dir> --write --data "${CLAUDE_PLUGIN_DATA}"
```

Caching lands in `${CLAUDE_PLUGIN_DATA}/profiles/<repo>.json`, which survives
plugin updates. Detection is keyed on a hash of the files it read, so
re-running is a no-op until the repo's build files change.

Report per repo: `confidence`, any `hazards`, and the derived test command.
**A `low` confidence is a finding, not a detail** — surface it with its
`confidence_reason` rather than burying it.

## Step 4 — Resolve the contributor docs

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/resolve-community.sh" --data "${CLAUDE_PLUGIN_DATA}"
```

Report which of the four sources answered (configured path, auto-detected
clone, cache, or a fresh fetch) and how old the docs are. Exit 4 means
unresolved — say so, and give the user the three fixes the script printed.
Never let a run proceed on remembered conventions.

## Step 5 — Offer the recommended deny rules

> **Read this to the user before touching anything.** A Claude Code plugin
> **cannot** ship permission rules — a plugin's `settings.json` honors only
> `agent` and `subagentStatusLine`. The rule that nothing is committed,
> commented, or pushed is enforced by
> `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/guard-destructive.sh`, which is active
> right now and needs no configuration.
>
> The deny block below is **defense-in-depth**, not the enforcement. Declining
> it leaves you fully protected by the hook.

Ask which scope they want, and **wait for an answer**:

| Scope | File | Effect |
|---|---|---|
| user | `~/.claude/settings.json` | every project on this machine |
| project | `<workspace>/.claude/settings.json` | this repo only; check it in for your team |
| neither | — | the hook alone enforces the rule |

Then show the exact diff — **this writes nothing**:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/merge-deny.sh" --target <chosen-settings.json>
```

Print its output verbatim: the rules that would be added, the rules already
present and kept, and the resulting `permissions.deny`. Say in one sentence
what it blocks: committing, pushing, tagging, rebasing and hard resets; every
mutating `gh pr` / `gh issue` / `gh api` call; the module-resolving `go`
subcommands; and writes to `go.mod`, `go.sum`, `vendor/` and `third_party/`.

**Only if the user explicitly confirms**, re-run with `--apply`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/merge-deny.sh" --target <chosen-settings.json> --apply
```

It backs the file up first, merges by union so existing rules survive, and
touches no other key. Silence is not confirmation. "Looks good" about the diff
is not permission to write — ask once more, plainly.

> Deny rules take effect on the next session start. Say so; otherwise the user
> checks `/permissions`, sees nothing, and assumes it failed.

## Step 6 — Print the "you're ready" summary

One screen, no more:

```
k8s-contributor is ready.

  workspace     <path>
  repos         <repo> (profile: <confidence>), ...
  docs          <resolved source>, <n> days old
  run state     <workspace>/.claude/k8s-contributor/state/<repo>/<issue>/
  cache         <CLAUDE_PLUGIN_DATA>  (profiles, docs, agent memory)
  deny rules    installed in <scope> | declined -- hook still enforces

  commands
    /k8s-triage <issue-url>       investigate, verdict, then STOP for your approval
    /k8s-fix    <issue-url>       plan, red-first fix, 6-way review, gate
    /k8s-verify [state-dir]       run the gates, read pass/fail off gate.json
    /k8s-report [state-dir]       package evidence into drafts
    /k8s-profile <repo-dir>       re-detect a repo's build commands

  THE ONE THING TO KNOW
    This plugin never commits, never comments, and never pushes.
    Every such action is written to a file and printed for you to run
    yourself. There is no flag that changes this.
```

Fill in the real values. If anything failed, list it under a
`needs attention` heading with the exact command that fixes it, and say the
plugin is usable for everything that does not depend on it.

Finally, suggest adding the run-state directory to the workspace's
`.gitignore`, and print the line rather than editing the file:

```
.claude/k8s-contributor/state/
```

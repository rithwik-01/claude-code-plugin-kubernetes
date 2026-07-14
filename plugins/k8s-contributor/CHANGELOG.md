# Changelog

All notable changes to the `k8s-contributor` plugin.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Bumping `version` in `plugin.json` is part of every release.** Users are
> pinned to the version string, so they receive nothing — not even a bug fix —
> until it changes. A release is: change the code, add an entry here, bump
> `version` in both `plugins/k8s-contributor/.claude-plugin/plugin.json` and
> the matching entry in `.claude-plugin/marketplace.json`.

## [0.1.0] — 2026-08-17

First release. Repackaged from a hand-rolled `.claude/` directory into an
installable plugin.

### Added
- `/k8s-setup` — first-run setup: discovers clones, checks prerequisites,
  caches a profile per repo, resolves the contributor docs, and offers to
  install the recommended `permissions.deny` block after showing the diff.
- Community-docs resolution with four fallbacks, ending in a sparse fetch of
  `kubernetes/community` cached under `${CLAUDE_PLUGIN_DATA}` with a 30-day
  staleness check (`scripts/resolve-community.sh`).
- `scripts/check-prereqs.sh` — reports tooling, `gh` auth, and Go version
  against the repo's `go.mod`. Installs nothing.
- `scripts/merge-deny.sh` — shows the exact `permissions.deny` diff and writes
  only with `--apply`, backing the file up and merging by union.
- `scripts/lib/paths.sh` — single source of truth for the run-state vs
  cross-run-cache split.
- Guardrail proof suite runnable against a fresh install with no permission
  rules configured (`scripts/prove-guardrails.sh` at the repo root).

### Changed
- **The approval guarantee is now carried by hooks alone.** A plugin cannot
  ship permission rules, so `hooks/scripts/guard-destructive.sh` is the primary
  enforcement layer rather than a backstop. Its refusal message states that no
  flag disables it.
- Run state moved to `<project>/.claude/k8s-contributor/state/`; profiles,
  fetched docs, and agent memory moved to `${CLAUDE_PLUGIN_DATA}`, which
  survives plugin updates.
- All script references now resolve through `${CLAUDE_PLUGIN_ROOT}`.
- Agents flattened from `agents/<group>/` to `agents/`, so they are addressed
  as `k8s-contributor:<name>` with no group segment.
- Skill preambles discover git clones in the workspace instead of naming
  specific repositories.
- Skills and agents use `(cd <repo> && git ...)` rather than the `git -C`
  flag, which the plugin's own guard blocks.

### Removed
- `color:` from every agent's frontmatter — not a supported field for
  plugin-shipped agents.
- Every absolute path belonging to the original author's machine.

### Known limitations
- `set -euo pipefail` is deliberately **not** applied to `detect-profile.sh`,
  `verify-all.sh`, or the hook scripts; see the header comment in each. Those
  scripts are built on tolerant exit codes, and `-e` there produces silently
  truncated results.
- Hook commands use shell form rather than exec form: `claude plugin validate`
  in v2.1.234 rejects the array form the documentation recommends.

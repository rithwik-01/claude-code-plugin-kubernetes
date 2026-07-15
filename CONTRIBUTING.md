# Contributing

Contributions are welcome, including first-time ones. Bug reports, a confusing
sentence in the documentation, an additional repository profile, or a new
reviewer agent are all useful. You do not need to be a Kubernetes maintainer to
help here.

If you are unsure whether something is worth filing, file it. A duplicate issue
costs seconds to close; an unreported bug can cost someone an hour.

## Ways to help

Ordered roughly by how much context they require.

| Effort | What | Where to start |
|---|---|---|
| Low | Fix a typo or an unclear explanation | Any `.md` file |
| Low | Report that something did not work on your machine | [Bug report](https://github.com/rithwik-01/claude-code-plugin-kubernetes/issues/new?template=bug_report.yml) |
| Low | Tell us a search that should have found this repo but did not | [Question](https://github.com/rithwik-01/claude-code-plugin-kubernetes/issues/new?template=question.yml) |
| Medium | Add a repository profile hazard we missed | `plugins/k8s-contributor/scripts/detect-profile.sh` |
| Medium | Improve a skill's instructions | `plugins/k8s-contributor/skills/*/SKILL.md` |
| High | Add a reviewer to the review fan-out | [docs/adding-a-reviewer.md](docs/adding-a-reviewer.md) |
| High | Add a verification gate | [docs/verification-matrix.md](docs/verification-matrix.md) |

## Local setup

You do not need to install the plugin to work on it. Load it in place:

```bash
gh repo clone rithwik-01/claude-code-plugin-kubernetes
cd claude-code-plugin-kubernetes
claude --plugin-dir "$PWD/plugins/k8s-contributor"
```

Edits to skills and agents take effect in the next session. Edits to
`plugin.json` or `hooks/hooks.json` require a restart.

## Before opening a pull request

Run these. They are the same checks CI runs, and they take seconds.

```bash
# every script parses
find . -name '*.sh' -not -path './.git/*' -exec bash -n {} \;

# the guardrails still hold (68 cases)
bash plugins/k8s-contributor/hooks/scripts/test-hooks.sh

# the approval guarantee survives with no permission rules (15 cases)
bash scripts/prove-guardrails.sh

# the manifest is valid
claude plugin validate ./plugins/k8s-contributor --strict
```

## The rules that matter

These are not style preferences. A pull request that breaks one will be sent
back, so they are worth reading first.

### 1. Never weaken the approval guarantee

The plugin must never be able to commit, comment, or push on its own. If a
change makes `scripts/prove-guardrails.sh` fail, the change is wrong, not the
test.

If you find a way to get a publishing command past `guard-destructive.sh`, that
is a security finding rather than a bug. Please open an issue with the exact
command; it will be treated as a priority.

### 2. No new dependencies

Everything here is POSIX-ish shell targeting **bash 3.2**, the system bash on
macOS, plus `jq`. No Python, no Node, and no bash 4 features: no associative
arrays, no `mapfile`, no `${var,,}`. If a change appears to need a dependency,
open an issue instead. That is a design discussion, not a pull request.

### 3. Fix causes, not symptoms

A widened timeout, an added sleep, a swallowed error, or a retry wrapped around
a race is not a fix. If you cannot reach the cause, say so in the pull request.
An honest partial fix with the gap named is more useful than a confident wrong
one.

### 4. Do not add `set -e` to the tolerant scripts

`detect-profile.sh`, `verify-all.sh`, and the hook scripts deliberately use
`set -u` alone. They are built around commands that are *expected* to exit
non-zero: probing for files most repositories do not have, and running gates
whose failure is the result being measured. Under `set -e` they abort early and
produce output that looks complete but is truncated. Each one explains this in
its header.

For a hook it is also a correctness bug. A non-matching `grep` would exit 1,
which is neither block (exit 2) nor allow (exit 0).

### 5. Match the surrounding code

Find the nearest similar thing and imitate it. The scripts share a shape: a
header comment explaining *why*, `--flag value` argument parsing, and explicit
failure messages that tell the reader what to do next.

## Commit messages

Conventional commits, one feature per commit.

```
feat: add a reviewer for RBAC surface changes
fix: stop detect-profile mis-parsing multi-target Makefile rules
docs: explain why the deny block is optional
test: cover scoped agent names in guard-scope
ci: run shellcheck on pull requests
```

Types in use: `feat`, `fix`, `docs`, `test`, `ci`, `refactor`, `chore`.

Write the body to explain what and why, not how. The diff already shows how.
Wrap at 72 columns.

## Releasing

For maintainers. Users are pinned to the version string and receive nothing
until it changes.

1. Bump `version` in `plugins/k8s-contributor/.claude-plugin/plugin.json`
2. Bump the matching entry in `.claude-plugin/marketplace.json`
3. Add a `CHANGELOG.md` entry for that version
4. Tag the release

CI fails the build if the two versions disagree or the changelog has no entry
for them, so this is difficult to get wrong by accident.

## Code of Conduct

This project follows the [CNCF Code of Conduct](CODE_OF_CONDUCT.md), the same
one the Kubernetes project uses.

## Questions

Open an issue using the question template. There is no such thing as a question
that is too basic here. If something confused you, the documentation is at
fault, and the answer belongs in it.

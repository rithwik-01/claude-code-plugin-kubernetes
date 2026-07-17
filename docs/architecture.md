# Architecture

## The graph

```
                        ┌──────────────────────────────────────────┐
                        │                                          │
  issue URL ──▶ INTAKE ──▶ TRIAGE FAN-OUT ──▶ TRIAGE SYNTH ──▶ VERDICT GATE
                        │   (5 parallel,          (1)              │
                        │    ephemeral,                            │
                        │    read-only)                            ├─▶ not-a-bug / dup /
                        │                                          │   needs-info / support
                        └──────────────────────────────────────────┘        │
                                                                            ▼
                                                                     REPORT ──▶ STOP
                                          (only on REAL + user approval)
                                                     │
                                                     ▼
                            ┌──── plan feedback ◀── PLAN REVIEWER (ephemeral)
                            ▼                              ▲
                        PLANNER (resident) ────────────────┘
                            │  (max 3 rounds, then escalate to human)
                            ▼
                        WORKER (resident = main thread; writes code + tests)
                            ▲                    │
                            │                    ├──▶ reviewer-correctness    ┐
                            │                    ├──▶ reviewer-conventions    │
                            │                    ├──▶ reviewer-tests          │ parallel,
                     feedback│                   ├──▶ reviewer-compat         │ ephemeral,
                            │                    ├──▶ reviewer-perf-security  │ read-only
                            │                    └──▶ reviewer-maintainability┘
                            │                                 │
                            │                                 ▼
                            │                            SYNTHESIZE
                            │                                 │
                            │                                 ▼
                            └───────── no ◀────────────  PASS? GATE  ──── yes ──▶ FINAL PACKAGING
                                (max 3 rounds,          (verifier +                (report.md,
                                 then escalate)          gate.json)                 pr-description.md,
                                                                                    issue-comment.md)
                                                                                        │
                                                                                        ▼
                                                                                    SEND TO USER
```

## Why residency is split the way it is

**Resident on the main thread**: intake, planner, worker, loop controller.

They share context across phases and they do the editing. A planner that
forgets what triage found writes a plan for a different bug; a worker that
cannot see the plan re-derives it. These need continuity more than isolation.

**Ephemeral subagents**: every reviewer, every triage investigator, the
synthesizer, the verifier.

Each of these consumes something enormous and returns something tiny. A
`code-locator` greps a 28,000-file repo; a `duplicate-hunter` pulls dozens of
`gh` payloads; a `reproducer` produces megabytes of test output. Run resident,
any one of them would blow out the context the *worker* needs. Run ephemeral,
they return a few hundred bytes of JSON and their scratch never enters the
conversation.

The split is a context-economics decision, not a security one — though it has a
security benefit: the read-only agents have no write tools, so a reviewer
cannot "fix" the thing it is judging.

## Where state lives, and why it is split

Two directories, chosen for two different lifetimes.

| What | Where | Why there |
|---|---|---|
| Run state — evidence, logs, `gate.json`, drafts | `<project>/.claude/k8s-contributor/state/<repo>/<issue>/` | Belongs next to the code being fixed. Inspectable, gitignorable, and two projects never share a run. |
| Cross-run cache — repo profiles, fetched community docs, agent memory | `${CLAUDE_PLUGIN_DATA}` | Survives plugin updates. Re-detecting profiles and re-fetching docs on every upgrade would be waste. |
| Nothing, ever | `${CLAUDE_PLUGIN_ROOT}` | **Replaced on every plugin update.** Anything written here is silently lost. |

`scripts/lib/paths.sh` is the only place that resolves any of this. Every
script sources it; nothing hard-codes a path.

Resolution order, most explicit first:

1. an explicit `--state-root` / `--data` flag
2. `K8S_STATE_ROOT` / `K8S_DATA_ROOT` in the environment
3. `CLAUDE_PROJECT_DIR` / `CLAUDE_PLUGIN_DATA` from Claude Code
4. a documented fallback (`$PWD`, `$HOME/.claude/k8s-contributor`)

`CLAUDE_PLUGIN_DATA` is substituted into skill markdown and hook commands, but
it is **not** guaranteed in the environment of a plain Bash tool call — which
is why every script also accepts `--data`, and why the skills always pass it.

## The approval guarantee

> Nothing is committed, commented, or pushed without explicit per-action
> approval.

In the original `.claude/` version this had four independent layers. Packaging
as a plugin **removed one of them**: a plugin's `settings.json` honors only
`agent` and `subagentStatusLine`, so `permissions.deny` cannot travel with it.

| Layer | Status |
|---|---|
| Agent prompts state the rule; read-only agents have no write tools | unchanged |
| Skill bodies end by *printing* commands, never running them | unchanged |
| `permissions.deny` rules | **cannot ship** — now offered by `/k8s-setup`, opt-in |
| `guard-destructive.sh` (`PreToolUse` on `Bash`) | **promoted to primary enforcement** |

The hook is written as though nothing else exists, because on a fresh install
nothing else does. It normalizes command text before matching, so `bash -c`,
`$( )`, backticks, `xargs`, `eval` and heredocs cannot hide a payload, and it
**fails closed**: a command it cannot parse is blocked.

`scripts/prove-guardrails.sh` demonstrates this against a scratch project with
no permission rules configured at all. It runs in CI.

## What the hook does not see

`guard-destructive.sh` receives the `PreToolUse` payload, whose
`tool_input.command` is the **text of the Bash command**. Everything it can
reason about comes from that string.

That is enough to catch nesting, because the nested payload is still *in* the
string: `bash -c "... git commit ..."`, `$( )`, backticks, `xargs`, and
heredocs all normalize down to the same token stream as the plain command.

It is **not** enough to catch a script file. `bash deploy.sh` is a short
command whose meaning lives in a file the hook never opens. Writing that file
through the `Write` tool is not content-inspected either, because
`guard-scope.sh` checks the destination path rather than the bytes.

Scanning executed files was considered and rejected for now. The check itself
is easy to write -- resolve the interpreter's file argument, read it, run the
existing normalization over its contents -- but its false-positive problem is
not hypothetical: `hooks/scripts/test-hooks.sh` and `scripts/prove-guardrails.sh`
both carry real publishing commands as test data. Content-scanning would block
this project's own test suites, along with any user script that merely mentions
a commit in a comment.

So the boundary is documented rather than papered over:

| Route | Inspected |
|---|---|
| `git commit -m x` | yes |
| `bash -c "make test && git commit -am x"` | yes |
| `$( )`, backticks, `xargs`, heredoc | yes |
| `eval "$CMD"` | blocked outright, precisely because it cannot be inspected |
| `bash script.sh` where the script commits | **no** |

The last row is a rule violation on the model's part rather than an approved
action. Every agent prompt and every skill states that wrapping a blocked
command is itself a violation, and the hook's refusal message says so
explicitly. But at that point it is enforced by instruction rather than
mechanically, and the difference is worth knowing in advance rather than
discovering later.

If you want it closed in your own fork, the change is roughly fifteen lines in
`guard-destructive.sh` plus an allowlist for the two test scripts. A pull
request that closes it without breaking the suites is welcome.

## Guardrails

| Hook | Event | Blocks |
|---|---|---|
| `guard-destructive.sh` | `PreToolUse` / `Bash` | any commit, push, tag, history rewrite, PR/issue mutation, or Prow slash-command — including nested forms. Fails closed. |
| `guard-deps.sh` | `PreToolUse` / `Bash`,`Edit`,`Write` | dependency files and the commands that rewrite them (`go get`, `go mod tidy`, vendoring). Escape hatch: an `allow-deps` file in the run state dir, created only after explicit approval. |
| `guard-scope.sh` | `PreToolUse` / `Edit`,`Write` | writes outside the workspace, plus per-agent confinement read from `agent_type` |
| `post-edit-gofmt.sh` | `PostToolUse` / `Edit`,`Write` | advisory only: reports `gofmt`/`goimports` drift |
| `log-subagent.sh` | `SubagentStop` | appends agent + verdict to the active run's `run.md` |

Two details worth knowing:

- `guard-scope.sh` strips the `k8s-contributor:` prefix from `agent_type`, so
  per-agent confinement matches whether an agent came from this plugin or from
  a local `.claude/agents/` copy.
- The guard blocks `git -C` and the `GIT_DIR` family outright. Redirecting git at
  another checkout is the documented way around path-based rules, so skills and
  agents use `(cd <repo> && git ...)` instead.

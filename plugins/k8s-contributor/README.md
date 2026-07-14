# k8s-contributor

Triage, fix, and verify Kubernetes issues with a parallel agent graph.

**It never commits, comments, or pushes.** Every such action is written to a
file and printed for you to run yourself, enforced by a `PreToolUse` hook that
ships with this plugin and has no bypass.

Full documentation, the graph, the gate table, and the limits are in the
[repository README](https://github.com/rithwik-01/claude-code-plugin-kubernetes).

## Install

```bash
claude plugin marketplace add rithwik-01/claude-code-plugin-kubernetes
claude plugin install k8s-contributor@claude-code-plugin-kubernetes
claude plugin enable  k8s-contributor@claude-code-plugin-kubernetes
```

Then run `/k8s-setup` from the directory holding your clones.

Requires Claude Code **v2.1.154+**; verified against v2.1.234.

## Commands

| Command | What it does |
|---|---|
| `/k8s-setup` | First run: find clones, check tooling, cache profiles, resolve docs, offer deny rules |
| `/k8s-triage <issue-url>` | Investigate in parallel, synthesize a verdict, stop for approval |
| `/k8s-fix <issue-url\|state-dir>` | Plan loop, red-first fix, six-way review, verifier gate |
| `/k8s-verify [state-dir]` | Run the applicable gates, read pass/fail off `gate.json` |
| `/k8s-report [state-dir]` | Package evidence into report, PR description, drafts |
| `/k8s-profile <repo-dir>` | Detect and cache a repo's real build/test commands |

## Where things are written

| What | Where |
|---|---|
| Run state (evidence, logs, `gate.json`, drafts) | `<project>/.claude/k8s-contributor/state/<repo>/<issue>/` |
| Cross-run cache (profiles, docs, agent memory) | `${CLAUDE_PLUGIN_DATA}` — survives updates |
| Nothing, ever | `${CLAUDE_PLUGIN_ROOT}` — replaced on every update |

Add `.claude/k8s-contributor/state/` to your project's `.gitignore`.

## Cost

~2,839 tokens always-on once enabled. The plugin ships `defaultEnabled: false`
so installing it does not switch it on. Hooks cost no model context.

## License

Apache-2.0.

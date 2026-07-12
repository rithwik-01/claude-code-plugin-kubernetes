---
name: k8s-verify
description: Run the applicable verification gates for a Kubernetes change and decide pass or fail from artifacts on disk - build, static and generated-code checks, the red-to-green regression proof, unit plus race, diff hygiene, integration, cluster, flake statistics, and the CI-parity checklist. Use to verify a fix, re-run gates, or check whether work is actually proven.
argument-hint: [state-dir]
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/verify-all.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/repro-loop.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/kind-up.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/kind-down.sh:*), Bash(go test:*), Bash(go build:*), Bash(make test:*), Bash(make verify:*), Bash(git diff:*), Bash(git status:*), Bash(git stash:*), Bash(git worktree:*), Read, Grep, Glob, Write
---

# /k8s-verify — run the gates, read the verdict off disk

State dir: **$ARGUMENTS** (defaults to the most recently touched run)

## Working tree right now

```!
cd "${CLAUDE_PROJECT_DIR:-$PWD}" && for d in */; do d="${d%/}"; [ -d "$d/.git" ] || continue; s=$( (cd "$d" && git status --porcelain) 2>/dev/null | wc -l | tr -d ' '); b=$( (cd "$d" && git rev-parse --abbrev-ref HEAD) 2>/dev/null); [ "$s" != "0" ] && echo "  $d [$b]: $s modified file(s)"; done; echo "  (repos not listed are clean)"
```

## Runs and their last gate result

```!
cd "${CLAUDE_PROJECT_DIR:-$PWD}" && for f in .claude/k8s-contributor/state/*/*/gate.json; do [ -f "$f" ] && echo "  $f -> $(jq -r '.overall + "  (class=" + .change_class + ", blocking=" + ((.blocking_gates//[])|join(",")) + ", missing=" + ((.missing_gates//[])|join(",")) + ")"' "$f" 2>/dev/null)"; done 2>/dev/null || echo "  (no gate.json yet)"
```

---

## Run the gate set

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/verify-all.sh \
  --state .claude/k8s-contributor/state/<repo>/<issue> \
  --repo  <repo-dir> \
  --class <change-class> --data "${CLAUDE_PLUGIN_DATA}" \
  --base  <base-ref> \
  --pkgs  <go package pattern> \
  --test  <TestName>
```

Add `--dry-run` to see the plan without executing, or `--only G0,G3` to
re-run a subset.

The **change class** comes from the triage synthesis, not from you. It selects
the gate set:

| Change class | Mandatory gates |
|---|---|
| `unit-logic` | G0–G4, G10 |
| `controller` | G0–G5, G10 |
| `api-type` | G0–G5, G9, G10 |
| `kubelet-node` | G0–G4, G6, G10 |
| `scheduler` | G0–G5, (G8), G10 |
| `flake` | G0–G4, **G7**, G10 |
| `cli-tool` | G0–G4, G6, G10 |
| `docs-only` | G0–G1, G4, G9 |

**Warn before a long gate.** The profile's `gate_runtime_estimate_s` has the
numbers; `make verify` on `kubernetes` is tens of minutes and a kind node-image
build is longer.

## The two gates that need hands

### G2 — the regression proof
`verify-all.sh` runs the green half. The **red** half must be staged by you:
stash the source change (not the test), run with `--expect-fail`, restore.
Full procedure and the seven traps:
`${CLAUDE_PLUGIN_ROOT}/skills/k8s-verification-matrix/references/g2-regression-proof.md`.

`run-gate.sh --expect-fail` marks G2 **fail if the red run passes** — a test
that passes without the fix proves nothing.

### G7 — flake statistics
Two-sided, and both sides are required:

```bash
# before the fix: need >=1 failure in N
${CLAUDE_PLUGIN_ROOT}/scripts/repro-loop.sh --dir <repo> --pkg <pkg> --test '^TestX$' \
  --mode reproduce --runs 20 --load --state <state-dir>

# after the fix: need 0 failures in 50
${CLAUDE_PLUGIN_ROOT}/scripts/repro-loop.sh --dir <repo> --pkg <pkg> --test '^TestX$' \
  --mode confirm --runs 50 --load --state <state-dir>
```

Cannot reproduce (exit 3)? Report `insufficient-info` and attach the CI
evidence. **Do not guess a fix.**

## Recording what cannot run here

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh --state <state> --id G6 --name node-e2e \
  --status deferred-to-ci \
  --reason 'node e2e is Linux-only; covered by pull-kubernetes-node-e2e-containerd'
```

`run-gate.sh` **refuses** a non-run status without `--reason`. That refusal is
deliberate — an unexplained skip is how a fake pass gets in. `deferred-to-ci`
must name the CI job. Never record something as `pass` because it could not run.

## The verdict

Read it, do not form it:

```bash
jq '{overall, missing_gates, blocking_gates, pass_without_evidence}' <state>/gate.json
```

PASS requires **both**:

1. `gate.json` `overall == "pass"`, **and**
2. zero `blocker` and zero `major` findings in `review-synthesis.md`.

Anything else is FAIL. Report the failing/missing gates and hand the ordered
action list back to the worker.

> Never re-run a gate until it passes and report only the last attempt. A gate
> that needed three tries is a flake finding, not a pass — record the attempts.

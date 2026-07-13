---
name: k8s-verification-matrix
description: The pass criteria for any Kubernetes-ecosystem change - the G0-G10 gate definitions, which gates are mandatory for which change class, the red-to-green regression proof, flake statistics, and the gate.json schema. Load before deciding whether work is verified, before running verification, and before reporting PASS or FAIL.
user-invocable: false
---

# Verification matrix

**Principle.** "Pass" is not "tests are green." It is:

> *the specific defect described in the issue is proven absent, by an artifact,
> at the cheapest tier that can prove it — and nothing else broke.*

Tests and cluster verification are not alternatives. They are different rungs,
and the **change class decides which rungs are mandatory**.

Two rules that override everything else in this file:

1. **The gate is decided by artifacts on disk, not by an agent's opinion.**
   Every gate result lives in `<state>/gates/<id>.json` and aggregates into
   `<state>/gate.json`. If there is no log file, the gate did not pass.
2. **A gate that did not run is not a pass.** It is `skipped` (blocking),
   `not-applicable`, or `deferred-to-ci` — and the last two must state a
   reason, with `deferred-to-ci` naming the CI job that covers it.

## Gate definitions

| Gate | Name | When required | `kubernetes/kubernetes` | sigs / small Go repos |
|---|---|---|---|---|
| **G0** | Build | always | `make WHAT=<pkgs>` / `go build ./...` | `make build` / `go build ./...` |
| **G1** | Static + generated-code verify | always | `make verify` (or scoped `hack/verify-*.sh`); fix with `hack/update-*.sh` / `make update` | `make verify` / `make lint` / `golangci-lint run` / `make generate && git diff --exit-code` |
| **G2** | **Regression proof (red→green)** | always | new/changed test fails at base, passes at HEAD; both logs captured | same |
| **G3** | Unit + race | always | `make test WHAT=./pkg/... KUBE_RACE=-race GOFLAGS="-count=1"` | `go test -race ./...` / `make test` |
| **G4** | Diff hygiene | always | `git diff --stat` reviewed; `go.mod`/`go.sum`/`vendor/` unchanged; no unrelated files | same |
| **G5** | Integration | cross-component semantics: apiserver, storage/etcd, scheduler, controllers, admission, RBAC | `hack/install-etcd.sh`; `export PATH=$PATH:$(pwd)/third_party/etcd`; `make test-integration WHAT=./test/integration/<area> KUBE_TEST_ARGS="-run ^TestX$"` | `envtest` / `setup-envtest` if the repo uses it |
| **G6** | Cluster / e2e | symptom only observable on a running cluster, or the repro steps are `kubectl`-level | see [g6-cluster.md](references/g6-cluster.md) | kind + install CRDs + drive the built binary |
| **G7** | Flake statistics | `kind/flake` issues, or any change touching concurrency/timing | see [g7-flakes.md](references/g7-flakes.md) | same |
| **G8** | Benchmark | perf-sensitive paths | `go test -bench=. -benchmem -count=10` + `benchstat base.txt new.txt` | same |
| **G9** | Docs / release note | user-facing behavior or API surface change | release note drafted; docs issue noted | same |
| **G10** | CI parity | always, as a **checklist, not a local run** | see [g10-ci-parity.md](references/g10-ci-parity.md) | read `.github/workflows/` and the repo's Prow config |

## Gate selection by change class

`verify-all.sh` derives the class from the touched paths in the diff plus the
triage classification. Do not choose it by vibe.

| Change class | Mandatory gates |
|---|---|
| Pure unit-level logic bug (`unit-logic`) | G0–G4, G10 |
| Controller / reconciliation (`controller`) | G0–G5, G10 (+G6 if cluster-observable) |
| API type / validation / defaulting / conversion (`api-type`) | G0–G5, G9, G10 (+ round-trip and generated-code checks in G1) |
| kubelet / node runtime (`kubelet-node`) | G0–G4, G6 (node-e2e; may be `deferred-to-ci` on macOS), G10 |
| Scheduler (`scheduler`) | G0–G5, G8 if perf-relevant, G10 |
| Flake (`flake`) | G0–G4, **G7**, G10 |
| CLI tool, e.g. gwctl (`cli-tool`) | G0–G4, G6 (kind + real CRDs), G10 |
| Docs only (`docs-only`) | G0–G1, G4, G9 |

## Running the gates

```bash
# whole applicable set for a class
${CLAUDE_PLUGIN_ROOT}/scripts/verify-all.sh --state <state-dir> --repo <repo-dir> \
    --class flake --base <base-ref> --pkgs ./test/integration/<area> --test TestFoo

# preview without executing
${CLAUDE_PLUGIN_ROOT}/scripts/verify-all.sh ... --dry-run

# one gate, by hand
${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh --state <state-dir> --id G3 --name unit-race \
    --cmd 'go test -race -count=1 ./pkg/foo/...' --dir <repo-dir>

# record a gate that legitimately cannot run here (a reason is REQUIRED)
${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh --state <state-dir> --id G6 --name node-e2e \
    --status deferred-to-ci \
    --reason 'node e2e is Linux-only; covered by pull-kubernetes-node-e2e-containerd'
```

`run-gate.sh` refuses `--status skipped|deferred-to-ci|not-applicable` without
`--reason`. That refusal is deliberate: an unexplained skip is how a fake pass
gets in.

## G2 — the regression proof

The single most important gate, and the one most often faked. **Mechanize it**;
never assert it from reading the diff. Full procedure, including the
worktree variant and the traps:
[references/g2-regression-proof.md](references/g2-regression-proof.md).

```bash
git stash push -- <source files only, NOT the test files>
go test ./<pkg>/ -run '^TestX$' -race -count=1     # MUST FAIL  -> evidence/G2-red.log
git stash pop
go test ./<pkg>/ -run '^TestX$' -race -count=1     # MUST PASS  -> evidence/G2-green.log
```

`run-gate.sh --expect-fail` asserts the red half and marks **G2 fail if the
"red" run passes**. A test that passes without the fix proves nothing.
`k8s-contributor:reviewer-tests` re-runs this independently rather than trusting the log.

## The PASS decision

The verifier may report PASS only when **both** hold:

1. `gate.json` `overall == "pass"` — every applicable gate is `pass` with a
   non-empty evidence path, or `not-applicable` / `deferred-to-ci` with a
   stated reason; **and**
2. `review-synthesis.md` contains **zero `blocker` and zero `major`** findings.

Anything else is FAIL, and the ordered action list goes back to the worker
(loop, max 3 rounds, then escalate to the human).

## References

- [references/schemas.md](references/schemas.md) — the JSON hand-off contract
  every agent returns, plus `gate.json` and `loop.json`
- [references/g2-regression-proof.md](references/g2-regression-proof.md)
- [references/g6-cluster.md](references/g6-cluster.md) — why plain
  `kind create cluster` does **not** contain your fix
- [references/g7-flakes.md](references/g7-flakes.md) — the two-sided
  statistical criterion
- [references/g10-ci-parity.md](references/g10-ci-parity.md) — the presubmits
  that actually gate the PR

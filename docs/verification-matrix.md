# The verification matrix

The most valuable thing this plugin carries. "Pass" is not "the tests are
green". It is:

> **the specific defect described in the issue is proven absent, by an
> artifact on disk, at the cheapest tier that can prove it — and nothing else
> broke.**

Every claim below is decided by a file, not by an agent's opinion.

## The gates

| Gate | Name | Required |
|---|---|---|
| G0 | Build | always |
| G1 | Static + generated-code verify | always |
| **G2** | **Regression proof (red→green)** | always |
| G3 | Unit + race | always |
| G4 | Diff hygiene | always |
| G5 | Integration | cross-component semantics |
| G6 | Cluster / e2e | cluster-observable symptoms |
| G7 | Flake statistics | `kind/flake`, concurrency and timing |
| G8 | Benchmark | performance-sensitive paths |
| G9 | Docs / release note | user-facing change |
| G10 | CI parity | always (a checklist, never a local run) |

## Which gates apply

The change class comes from triage synthesis, not from the model.

| Change class | Mandatory gates |
|---|---|
| `unit-logic` | G0–G4, G10 |
| `controller` | G0–G5, G10 (+G6 if cluster-observable) |
| `api-type` | G0–G5, G9, G10 |
| `kubelet-node` | G0–G4, G6, G10 |
| `scheduler` | G0–G5, G8 if perf-relevant, G10 |
| `flake` | G0–G4, **G7**, G10 |
| `cli-tool` | G0–G4, G6, G10 |
| `docs-only` | G0–G1, G4, G9 |

## How a verdict is reached

`overall: "pass"` in `gate.json` requires every applicable gate to be either:

- `pass` **with a non-empty evidence path**, or
- `not-applicable` / `deferred-to-ci` **with a stated reason**.

A `skipped` gate, a missing gate, and a `pass` with no evidence each force
`fail`. `run-gate.sh` **refuses** a non-run status without `--reason`, and
`deferred-to-ci` must name the CI job that will cover it. That refusal is the
point: an unexplained skip is how a fake pass gets in.

The final PASS additionally requires **zero `blocker` and zero `major`
findings** in `review-synthesis.md`. Both conditions, or it is a FAIL.

## The two gates that actually catch things

### G2 — the regression proof

Run the test **before** the fix and require it to **fail**:

```bash
run-gate.sh --state <state> --id G2 --name red --expect-fail --cmd '<test cmd>'
```

`--expect-fail` inverts the pass condition, so G2 is marked **fail if the red
run passes**. A test that passes without the fix proves nothing about the fix.
`k8s-contributor:reviewer-tests` re-runs this independently rather than
trusting the log it was handed.

Stage the red half by stashing the **source** change and keeping the **test**.

### G6 — the cluster gate

`kind create cluster` on its own boots a **released** node image and will not
contain your change. `kind-up.sh` builds the node image from the working tree
by default; `--no-build` is only correct when the change is not in the cluster
binaries (a CLI tool driven against a stock cluster).

Node e2e is Linux-only. On macOS it is recorded `deferred-to-ci` naming
`pull-kubernetes-node-e2e-containerd` — never `pass`.

## Never

- Never re-run a gate until it passes and report only the last attempt. A gate
  that needed three tries is a flake finding; record the attempts.
- Never downgrade a `blocker` to make the gate go green.
- Never record something as `pass` because it could not run.

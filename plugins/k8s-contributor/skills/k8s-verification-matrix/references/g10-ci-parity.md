# G10 — CI parity checklist

G10 is **always a checklist, never a local run**. The real arbiter of a
Kubernetes PR is Prow. The point of this gate is to state honestly what was
proven locally and what still has to be proven in CI.

The verifier writes `artifacts/ci-parity.md` mapping each presubmit that will
gate the PR to what ran locally.

## `kubernetes/kubernetes` presubmits

| Presubmit | What it gates | Local counterpart |
|---|---|---|
| `pull-kubernetes-verify` | generated code, gofmt, boilerplate, godeps | G1 (`make verify`) |
| `pull-kubernetes-unit` | unit tests | G3 |
| `pull-kubernetes-integration` | `test/integration` with etcd | G5 |
| `pull-kubernetes-typecheck` | cross-platform typecheck | G0 / G1 |
| `pull-kubernetes-dependencies` | `go.mod`, `go.sum`, `vendor/` consistency | G4 (must be **unchanged**) |
| `pull-kubernetes-e2e-kind` | e2e on a kind cluster | G6 |
| `pull-kubernetes-e2e-kind-ipv6` | same, IPv6 | usually `deferred-to-ci` |
| `pull-kubernetes-conformance-kind-ga-only-parallel` | GA conformance | usually `deferred-to-ci` |
| `pull-kubernetes-node-e2e-containerd` | node/kubelet e2e | G6; **Linux-only**, `deferred-to-ci` on macOS |

The set is not fixed forever — confirm against the PR's own check list when it
exists, and against `kubernetes/test-infra` config. Do not present this table
as authoritative if the run can see the real one.

## sigs repos

Read the repo's actual CI configuration rather than assuming:

```bash
ls .github/workflows/ && cat .github/workflows/*.yml     # GitHub Actions
cat .prow.yaml 2>/dev/null                               # in-repo Prow config
cat OWNERS                                               # who must approve
```

The generated profile records `github_workflows` and `uses_prow` for exactly
this purpose (`${CLAUDE_PLUGIN_DATA}/profiles/<repo>.json`).

Worked example from this workspace:

- `kube-openapi` — one GitHub Actions workflow (`ci.yml`), no Makefile; the
  local counterpart of CI is `go build ./...` + `go test ./...`.
- `gwctl` — no workflows; Prow-gated, `hack/verify-all.sh` is the verify step.
  Note its `make` targets depend on `deps`, which runs `go mod tidy && go mod
  vendor`; CI tolerates that, but this system must not, so the profile routes
  around it.

## The rule

Any gate not runnable locally is recorded as **`deferred-to-ci` with the job
name and the reason** — never as `pass`.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh --state <state-dir> --id G6 --name node-e2e \
  --status deferred-to-ci \
  --reason 'Linux-only; covered by pull-kubernetes-node-e2e-containerd'
```

## `artifacts/ci-parity.md` shape

```markdown
| Presubmit | Gate | Ran locally? | Evidence / why not |
|---|---|---|---|
| pull-kubernetes-verify | G1 | yes | evidence/G1-static-and-generated.log |
| pull-kubernetes-unit | G3 | yes | evidence/G3-unit-race.log |
| pull-kubernetes-node-e2e-containerd | G6 | no | Linux-only; host is Darwin |
```

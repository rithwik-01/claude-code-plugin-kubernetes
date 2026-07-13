# G6 — cluster verification with kind, in detail

## The critical subtlety

**`kind create cluster` alone runs a *released* node image and will not
contain your fix.** Verifying a change to kubelet, kube-apiserver,
kube-scheduler, or kube-controller-manager requires building the node image
from the working tree first. Skipping this step and then reporting "verified on
a cluster" is a false pass — the cluster was running someone else's binary.

## Building a node image from source

`${CLAUDE_PLUGIN_ROOT}/scripts/kind-up.sh` does this by default:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/kind-up.sh --repo <kubernetes-src> --name fix-<issue> \
    --state <state-dir> [--config <state-dir>/artifacts/kind-config.yaml]
```

which runs, from the kubernetes source tree:

```bash
kind build node-image --image kindest/node:fix-<issue>   # compiles k8s from THIS source
kind create cluster --name fix-<issue> \
  --image kindest/node:fix-<issue> \
  [--config <state-dir>/artifacts/kind-config.yaml]      # multi-node / feature gates
kubectl cluster-info --context kind-fix-<issue>
```

Use `--config` when the repro needs more than one node, a specific feature
gate, or particular apiserver flags. Write that config into the run's
`artifacts/` directory so it is part of the evidence.

Then either replay the reporter's exact steps, or run the focused e2e suite:

```bash
make WHAT=test/e2e/e2e.test                    # -> _output/bin/e2e.test
./_output/bin/e2e.test \
  --provider=local \
  --kubeconfig="$HOME/.kube/config" \
  --ginkgo.focus="<regex>" \
  --ginkgo.v
```

## Teardown always, evidence first

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/kind-down.sh --name fix-<issue> --state <state-dir>
```

`kind-down.sh` runs `kind export logs` into `<state>/evidence/kind-logs-<name>/`
**before** deleting, so a failed G6 still leaves the diagnostic behind.
`kind-up.sh` exports logs on a creation failure for the same reason.

## Node-level (kubelet) changes are Linux-only

```bash
make test-e2e-node FOCUS=<regex>
```

This does not run on macOS. On a macOS host, record G6 as **`deferred-to-ci`**
with the reason and the exact Prow job that will cover it:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh --state <state-dir> --id G6 --name node-e2e \
  --status deferred-to-ci \
  --reason 'node e2e is Linux-only; this host is Darwin. Covered by pull-kubernetes-node-e2e-containerd'
```

Never record it as `pass`. `verify-all.sh` does this automatically when the
change class is `kubelet-node` and `uname -s` is not `Linux`.

## sigs CLI projects (gwctl and similar)

The binary under test runs *outside* the cluster, so a stock node image is
correct here — pass `--no-build`:

1. `kind create cluster` (plain image is fine — the change is in the CLI, not
   in the cluster binaries), or `kind-up.sh --no-build --name fix-<issue>`
2. install the CRDs the repo's tests expect (for gwctl: the Gateway API CRDs —
   read the repo's own test setup for the exact version and manifests rather
   than assuming)
3. run the **locally built** binary against the cluster
4. assert on real output, not on a mock

## Preconditions

`kind-up.sh` refuses to start when `kind`, `kubectl`, or a container runtime is
missing, rather than producing a misleading failure. Building a node image
compiles Kubernetes: budget tens of minutes and warn the user before starting.

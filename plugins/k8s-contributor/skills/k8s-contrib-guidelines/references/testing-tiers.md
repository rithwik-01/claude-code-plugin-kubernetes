# Testing tiers — which one proves what

From `community/contributors/devel/sig-testing/`:
`testing.md`, `integration-tests.md`, `e2e-tests.md`, `flaky-tests.md`, and
`devel/sig-node/e2e-node-tests.md`.

Pick the **cheapest tier that can actually decide**. Escalating past that
wastes 40 minutes; stopping short of it proves nothing.

| Tier | Proves | Cost | Use when |
|---|---|---|---|
| Static reading | a code path cannot/must produce the symptom | free | always first — often decisive on its own |
| Unit | one function's logic, error paths, edge cases | seconds | the defect is inside one package |
| Integration | cross-component semantics against a real apiserver + etcd | minutes | apiserver, storage, scheduler, controllers, admission, RBAC |
| Cluster / e2e | end-user-observable behavior on a running cluster | tens of minutes | the symptom only appears on a live cluster, or the repro is `kubectl`-level |
| Node e2e | kubelet against a real container runtime | tens of minutes, **Linux only** | kubelet / node runtime changes |
| Statistical | a flake is real, and later that it is gone | long | `kind/flake`, or any concurrency/timing change |

## Unit

- Table-driven is the preferred form for multiple scenarios.
- **Must pass on macOS and Windows.** Linux-only behavior: skip on Windows
  (preferred when it runs Linux-specific commands) or compile it out (required
  when the code will not build on Windows).
- Never sleep-and-assert. Poll and retry.

## Integration

- Only local resources: etcd, or a service on localhost.
- Each test creates its own apiserver instance and config.
- Required for all significant features, including new `kubectl` commands.

```bash
hack/install-etcd.sh                      # -> ./third_party/etcd
export PATH=$PATH:$(pwd)/third_party/etcd
make test-integration WHAT=./test/integration/<area> \
     KUBE_TEST_ARGS="-run ^TestX$"
```

`TEST_ETCD_DIR` relocates the internally started etcd's data when the temp
volume is small or slow. Setting `KUBE_TEST_ARGS` restricts to the `v1` API and
skips the watch-cache variant.

## E2E

- Ginkgo-based, under `test/e2e`. Focus with `--ginkgo.focus=<regex>`.
- Read `writing-good-e2e-tests.md` before adding one — e2e is the most
  expensive tier and the easiest to make flaky.
- Node e2e (`make test-e2e-node FOCUS=<regex>`) is **Linux-only**; on macOS
  record it `deferred-to-ci` naming `pull-kubernetes-node-e2e-containerd`.

## Flakes — the policy

The project has a **zero-flake policy**; jobs must not auto-retry on failure
(in force since 2019-12-13, reaffirmed 2023).

**Blocker-severity non-fixes**, unless the plan proves the underlying race or
ordering bug is gone:

- raising a timeout · adding a `time.Sleep` · adding a retry ·
  loosening an assertion · marking the test `[Flaky]`

Quarantining with `[Flaky]` is a last resort, and it comes with obligations:
an issue in the current release milestone, assigned to the owning SIG, labeled
`priority/critical-urgent`, `lifecycle/frozen`, `kind/flake`.

### Writing tests that do not flake

- Tolerate concurrent tests: match on resource name **and** namespace.
- Ask only for the resources you need.
- No tight deadlines and no unbounded ones. Non-`[Slow]` tests time out at
  5 minutes; poll for `wait.ForeverTestTimeout` rather than a hard 10s.
- Prefer informers and wait loops over fixed delays.
- Log for forensics: what the test is doing, what check failed and how, and why
  a polling loop is still retrying ("expected 3 widgets, found 2, will retry").

### Hunting an existing flake

- [go.k8s.io/triage] — aggregated failures for the last two weeks, filterable
  by job, test name, or failure text
- [testgrid.k8s.io] — grid view; sort by flakiness
- `flakes-latest.json` — top 10 flakes of the past week across PR jobs
- the `kind/flake` label on kubernetes/kubernetes

A good flake report quotes the **entire** log of the failing test, not just the
failure line, and links spyglass for the durable artifacts.

[go.k8s.io/triage]: https://go.k8s.io/triage
[testgrid.k8s.io]: https://testgrid.k8s.io

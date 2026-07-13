---
name: k8s-codebase-patterns
description: How to write a change that looks native to the Kubernetes package it lands in - find the nearest analogous code and imitate it, use the helpers the package already imports, never add a dependency, and never invent a new pattern. Load before writing or reviewing any Go code in a kubernetes or kubernetes-sigs repo.
user-invocable: false
---

# Writing code that looks native

The goal is a diff a maintainer reads once and recognizes as their own style.
A technically correct change written in a foreign idiom costs review rounds and
often gets rejected.

## The method: anchor before you write

**Never write from a blank page.** Before the first line:

1. Find the **nearest analogous code** — the same operation, one file over, or
   the sibling controller/validator/handler that already does the shape of
   thing you need.
2. Read it for: receiver naming, error wrapping, logging calls, context
   handling, lock naming, how it is tested.
3. Cite it as `file:line` in `plan.md` under **Codebase-pattern anchor**.
4. Write your change to match that anchor.

A new pattern requires justification in the plan. "It is cleaner" is not one.

```bash
# find the anchor
grep -rn "func (.*) SyncPod" pkg/kubelet/ | head
rg -t go "wait.PollUntilContextTimeout" pkg/controller/ | head
ls pkg/registry/core/pod/          # what does the sibling resource do?
```

## Hard rules

### Zero new third-party dependencies

No `go get`, no edits to `go.mod` / `go.sum` / `vendor/` / `third_party/`.
Enforced by `guard-deps.sh`, and a dependency change is a **blocker** finding.

Before reaching for anything new, look for what already exists:

| You want | The repo already has |
|---|---|
| poll until a condition | `k8s.io/apimachinery/pkg/util/wait` — `PollUntilContextTimeout`, `PollUntilContextCancel` |
| set operations | `k8s.io/apimachinery/pkg/util/sets` |
| structured errors from validation | `k8s.io/apimachinery/pkg/util/validation/field` — `field.Invalid`, `field.Required`, `ErrorList` |
| aggregate several errors | `k8s.io/apimachinery/pkg/util/errors` — `NewAggregate` |
| deep-compare in tests | `google/go-cmp` or the package's existing choice |
| fake clientset | `k8s.io/client-go/kubernetes/fake` |
| test logging with a context | `k8s.io/klog/v2/ktesting` |
| shared test helpers | `k8s.io/kubernetes/test/utils` |
| retry on conflict | `k8s.io/client-go/util/retry` — `RetryOnConflict` |
| work queues | `k8s.io/client-go/util/workqueue` |

Check the **package's own imports first** — the right helper is usually already
imported by the file you are editing.

### Use the assertion library the repo already uses

The profile records it (`${CLAUDE_PLUGIN_DATA}/profiles/<repo>.json` → `assertion_library`).
In this workspace: `kubernetes` and `kube-openapi` lean on `stretchr/testify`,
`gwctl` on `google/go-cmp`, `community` on plain stdlib `testing`. Use **that
one**, in that repo, even if you prefer another.

### Never hand-edit generated code

Files with `// Code generated ... DO NOT EDIT.` are regenerated, never edited.
Run the repo's update script (`hack/update-codegen.sh`, `make update`,
`make generate`) and commit the result. G1/G4 catch hand edits.

## Go idioms as used here

### Errors

```go
if err != nil {
    return fmt.Errorf("failed to update pod status for %q: %w", podKey, err)
}
```

Lowercase message, no trailing punctuation, wrap with `%w` when the caller may
need `errors.Is`/`errors.As`. **Never swallow an error to make a symptom go
away** — that is a workaround and a blocker.

### Logging

Structured klog only (see the contrib-guidelines skill for the full rules):

```go
klog.V(4).InfoS("Syncing pod", "pod", klog.KObj(pod), "podUID", pod.UID)
klog.ErrorS(err, "Failed to sync pod", "pod", klog.KObj(pod))
```

Use `klog.KObj` / `klog.KRef` for object references rather than string
formatting. Match the surrounding verbosity levels rather than inventing one.

### Locks

`lock sync.Mutex`, never embedded. Several locks get distinct names —
`stateLock`, `mapLock`. Document the ordering if more than one can be held, and
keep that order everywhere.

### Context

Propagate the caller's `context.Context` as the first parameter; do not create
`context.Background()` deep in a call chain. Respect cancellation in loops.

### Naming

Consider the package name and avoid stutter: `storage.Interface`, not
`storage.StorageInterface`. Package name matches its directory
(`pkg/controllers/autoscaler` → `package autoscaler`). No `util` packages —
name the domain (`wait.Poll`).

## Tests that look native

- **Table-driven**, with the package's existing table shape — some use
  `map[string]struct{...}`, some a `[]struct{ name string; ... }` slice.
  Copy the local one.
- Name subtests so `-run 'TestX/case_name'` selects one.
- Use the package's existing fixtures and helpers before writing new ones.
- Deterministic: no `time.Sleep`, no wall-clock assumptions, no unbounded
  retries. Poll with `wait.PollUntilContextTimeout`.
- Cover the **negative** case, not just the happy path.
- Unit tests must pass on macOS and Windows.

```go
func TestValidatePodName(t *testing.T) {
    tests := []struct {
        name    string
        input   string
        wantErr bool
    }{
        {name: "valid", input: "nginx", wantErr: false},
        {name: "empty is rejected", input: "", wantErr: true},
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            err := ValidatePodName(tc.input)
            if (err != nil) != tc.wantErr {
                t.Errorf("ValidatePodName(%q) error = %v, wantErr %v", tc.input, err, tc.wantErr)
            }
        })
    }
}
```

## Smallest correct diff

- Fix the root cause once, where all callers route through — not once per
  caller.
- Do not reformat, rename, or tidy code you are not fixing. Unrelated churn
  hides the actual change and fails G4.
- No new abstraction for a single call site.
- Comments explain **why**, not what. If a reviewer would ask "why is this
  here?", answer it in a comment.

# API changes, compatibility, logging, metrics

From `community/contributors/devel/sig-architecture/` (`api-conventions.md`,
`api_changes.md`, `feature-gates.md`) and `devel/sig-instrumentation/`
(`logging.md`, `metric-instrumentation.md`, `metric-stability.md`).

These are long documents. Read the relevant section before citing it; the
summaries below exist to tell you *which* section to open.

## The bug-fix boundary

> **A bug fix does not change an API.** If the change touches a versioned API
> type, defaulting, validation, conversion, or a serialized field, stop and
> say so. That is a KEP/API-review conversation, not something to slip into a
> bug-fix PR.

Signals that you have crossed the line:

- editing anything under `staging/src/k8s.io/api/`, `pkg/apis/*/types.go`
- changing a `+optional`, `+default`, or other marker comment
- changing what `validation.go` accepts or rejects
- changing `zz_generated.conversion.go` inputs, or any generated file by hand
- changing the serialized JSON/protobuf shape, including field order effects
- changing a metric name, label set, or stability level

## API change mechanics

When an API change *is* the sanctioned work (`api_changes.md`):

- Round-trip must hold: internal → versioned → internal is lossless. There are
  fuzzing round-trip tests; they will catch you.
- Regenerate rather than hand-edit: `hack/update-codegen.sh`, `make update`.
  `make verify` (G1) fails when generated output drifts.
- Defaulting and validation both need tests, including the negative cases.
- Backward compatibility: an existing object stored in etcd must still
  deserialize and behave the same.

## Feature gates

From `feature-gates.md`. A behavior change usually needs to sit behind a gate.

- Alpha: off by default. Beta: on or off per policy for the release. GA:
  on, and the gate is eventually removed.
- Gate graduation changes defaults — that is a user-facing change and needs a
  release note.
- **Version skew** matters: an N-1 kubelet talking to an N apiserver, and the
  reverse. Ask what happens when the gate is on at one end and off at the
  other.
- A regression that only occurs with an off-by-default alpha feature enabled is
  **not** eligible for a cherry-pick.

## Logging conventions

Kubernetes uses [klog], migrating to [logr] via structured and contextual
logging. Match the surrounding package — do not introduce a style it does not
already use.

- Use **structured** methods: `klog.InfoS`, `klog.ErrorS`, and verbosity
  variants like `klog.V(2).InfoS`.
- The old printf-style calls (`klog.Infof`, `klog.Errorf`) are **no longer
  recommended**; do not add new ones.
- Variadic args are key/value pairs: always an even count, key first and a
  `string`.

```go
klog.InfoS("Received HTTP request", "method", "GET", "URL", "/metrics", "latency", time.Second)
```

**Message style:** start with a capital; no trailing period; active voice;
past tense ("Could not delete B", not "Cannot delete B"); name the object type
("Deleted pod", not "Deleted").

**Do not log in shared libraries** such as `client-go` — return the `error` and
let the caller decide, because CLIs need to control their own output.

[klog]: https://github.com/kubernetes/klog
[logr]: https://github.com/go-logr/logr

## Metric stability

From `metric-stability.md` (KEP-1209). Metric stability level is a
compatibility promise, so changing a metric is an API change.

| Level | Guarantee |
|---|---|
| `ALPHA` | no guarantees; may change or disappear |
| `BETA` | not deleted without graduating or being deprecated for ≥1 release (or 4 months) |
| `STABLE` | must **not change**; not deleted/renamed without deprecation for ≥3 releases (or 9 months) |
| `INTERNAL` | not part of the public surface |

- **Adding or removing a *label* on a stable metric is not permissible.** To do
  it you must introduce a new metric and deprecate the old one. (Adding or
  removing label *values* is fine — that is ingestion-compatible.)
- Renaming a stable metric = deprecate + introduce; never rename in place.
- Deprecation is expressed as metadata, e.g. `DeprecatedVersion: "1.15"`, and a
  deprecated stable metric keeps its stable guarantees.
- Stable metrics go through API review.

## Error wrapping

Match the package. The prevailing idiom is:

```go
if err != nil {
    return fmt.Errorf("failed to sync pod %q: %w", podKey, err)
}
```

Wrap with `%w` when the caller may need `errors.Is`/`errors.As`; use `%v` only
when deliberately severing the chain. Never swallow an error to make a symptom
disappear — that is a workaround, and a blocker.

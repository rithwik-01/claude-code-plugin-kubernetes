# Triage report — kubernetes-sigs/gwctl#110

**Verdict: `SUPPORT` (not a defect)** · classification: **`feature`** · confidence: high

"Add watch flag" — a feature request for `-w`/`--watch` on `gwctl get`,
labelled `kind/feature`, `good first issue`, `help wanted`. 8 comments.

## Why the fix pipeline does not apply

`/k8s-fix` implements *defect* repairs: it requires a root cause at file:line
and a regression test that fails before the change. A feature request has
neither — there is no defect and no prior correct behavior to restore. Running
the plan loop here would produce a design document dressed up as a root-cause
analysis.

This needs a design discussion with the maintainers first (`gauravkghildiyal`,
`snorwin`, `robscott`, `youngnick` per OWNERS), not a triage-to-fix run.

> **Vocabulary gap, flagged rather than papered over:** the verdict set
> (`REAL` / `DUPLICATE` / `NOT-REPRODUCIBLE` / `WORKING-AS-INTENDED` /
> `NEEDS-INFO` / `SUPPORT` / `ALREADY-FIXED`) has no slot for a feature
> request. `SUPPORT` is the only "not a defect, stop here" verdict available,
> so it is used, but the accurate classification is `feature`. Adding a
> `FEATURE` verdict would be a one-line change to the synthesizer and the
> triage skill.

## Observation for the user

The local clone is on branch `feat/get-watch` (HEAD `56692a9`, clean tree) —
work on this feature already appears to be in progress here. Confirm before
starting anything new.

## Profile switch — proof of genericity

The same system, unchanged, derived a completely different command set for
this repo:

| | kubernetes | gwctl |
|---|---|---|
| build | `make WHAT=<pkgs>` | `go build ./...` |
| test+race | `make test WHAT=… KUBE_RACE=-race` | `go test -race -count=1 ./...` |
| verify | `make verify` | `hack/verify-all.sh` |
| lint | `make lint` | `golangci-lint run` |
| etcd / envtest | etcd | envtest |
| assertion library | `stretchr/testify` | `google/go-cmp` |
| change class | `flake` → G0–G4, **G7**, G10 | `cli-tool` → G0–G4, **G6**, G10 |

`make verify` is *not* used for gwctl even though the target exists: the
detector found that `make build`, `make test`, and `make verify` all depend on
a `deps` target running `go mod tidy && go mod vendor`, which rewrites
dependency files and is blocked by `guard-deps.sh`. It routed around all three.

## Nothing was changed and nothing was posted.

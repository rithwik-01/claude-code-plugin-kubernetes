---
name: k8s-profile
description: Detect and cache the build/test/verify profile for a Kubernetes-ecosystem repo clone - real Makefile targets, test tiers, etcd and kind requirements, assertion library, OWNERS, SIG, PR template, generated-code refresh command, and per-gate runtime estimates. Use before running any gate against a repo, or when build commands are unknown or look wrong.
argument-hint: <repo-dir>
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/detect-profile.sh:*), Read, Grep, Glob
---

# /k8s-profile — detect a repo's build profile

Target: **$ARGUMENTS** (a repo directory; a sibling of the workspace root)

## Workspace state

```!
cd "${CLAUDE_PROJECT_DIR:-$PWD}" && for d in */; do [ -d "$d.git" ] && echo "  ${d%/}"; done; echo "(directories above are git clones in the workspace root)"
```

Already-cached profiles:

```!
ls -1 "${CLAUDE_PLUGIN_DATA}"/profiles/*.json 2>/dev/null | xargs -n1 basename 2>/dev/null || echo "(none yet)"
```

## Run it

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/detect-profile.sh <repo-dir> --write --data "${CLAUDE_PLUGIN_DATA}"
```

- `--write` caches to `${CLAUDE_PLUGIN_DATA}/profiles/<repo>.json` — the
  cross-run cache, which survives plugin updates.
- **Always pass `--data "${CLAUDE_PLUGIN_DATA}"`.** That variable is
  substituted into this skill's text, but it is *not* present in the
  environment of a plain Bash tool call, so the script cannot find it itself.
- The cache is keyed on a hash of the inputs it read (Makefile, go.mod,
  `.go-version`, golangci config, `.prow.yaml`, OWNERS, CONTRIBUTING, and the
  `hack/` and `.github/workflows/` listings). Re-running is a no-op until one
  of those changes.
- `--force` regenerates regardless.

## What it derives, and from what

Never hard-code a repo's commands. Detection order:

1. **Makefile** — real targets, parsed from rule lines. It handles multi-target
   rules (`check test:` is how `kubernetes` defines `test`), and skips
   `.PHONY`, variables, and pattern rules.
2. **`hack/`** — `verify-*.sh`, `update-*.sh`, `install-etcd.sh`,
   `local-up-cluster.sh`, `ginkgo-e2e.sh`, `update-codegen.sh`.
3. **`go.mod` / `.go-version` / golangci config** — module path, Go version.
4. **`.github/workflows/`, `.prow.yaml`, `OWNERS`, `OWNERS_ALIASES`,
   `SECURITY_CONTACTS`** — CI system, reviewers, SIG label.
5. **Test layout** — `test/integration`, `test/e2e`, `test/e2e_node`, `pkg`,
   `cmd`, `staging`, and the PR/issue templates.
6. **Frameworks** — envtest, kind, ginkgo, and **which assertion library the
   repo's own `_test.go` files actually use most**. The fix must use that one.

## Hazards

The profile records `hazards[]` for targets that are unsafe under this
workspace's rules, and routes the gate commands around them.

Worked example: in `gwctl`, `make build`, `make test`, and `make verify` all
depend on a `deps` target that runs `go mod tidy && go mod vendor`. Running
them rewrites `go.mod`/`go.sum`/`vendor/`, which `guard-deps.sh` blocks. The
detector notices, flags all three, and emits the plain `go build ./...` /
`go test -race -count=1 ./...` equivalents instead.

Check `hazards` before trusting any `make` invocation in a repo you have not
profiled.

## Low confidence

When the signals are too thin, the profile records
`"confidence": "low"` (or `"medium"`) with a `confidence_reason`.

**Do not guess past it.** Read the reason, then ask the user **one targeted
question** — the specific command you could not derive — rather than inventing
a command that will fail ten minutes into a gate.

Worked example: `kube-openapi` has no Makefile at all, so it comes back
`medium` with *"no Makefile: commands fall back to the plain go toolchain"*.
That fallback is correct there, and the note tells you it was a fallback rather
than a detected target.

## Reading the result

```bash
jq '{confidence, confidence_reason, commands, requires, hazards, assertion_library}' \
  ${CLAUDE_PLUGIN_DATA}/profiles/<repo>.json
```

Fields the rest of the system relies on: `commands.*` (gate commands),
`requires.etcd|kind|envtest`, `assertion_library`, `pr_template`,
`owners_reviewers`, `sig_label`, `uses_prow`, `sensitive_paths`,
`gate_runtime_estimate_s` (so the verifier can warn before a 40-minute run),
and `gate_sets_by_change_class`.

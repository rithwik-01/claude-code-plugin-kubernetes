#!/usr/bin/env bash
# detect-profile.sh -- derive a build/test profile for a Kubernetes-ecosystem
# repo by reading the repo, never by hard-coding repo names.
#
# Usage:
#   detect-profile.sh <repo-dir> [--write] [--force] [--data <dir>]
#
#   (no flag)  print the profile JSON to stdout
#   --write    also cache it to <plugin-data>/profiles/<repo>.json
#   --force    regenerate even if the cached input hash still matches
#   --data     override the cross-run cache root (default: $CLAUDE_PLUGIN_DATA)
#
# Detection order (build spec section 5):
#   1. Makefile targets        2. hack/ scripts        3. go.mod / .go-version
#   4. CI config + OWNERS      5. CONTRIBUTING/test layout
#   6. envtest / kind / ginkgo / assertion library
#
# Emits "confidence": "low" when the signals are too thin to act on; the
# calling skill is instructed to ask one targeted question rather than guess.
#
# bash 3.2 compatible (macOS system bash). No dependencies beyond coreutils,
# awk, sed, grep and (optionally) jq / shasum.

# Deliberately `set -u` and NOT `set -e`/`pipefail`: detection is ~100 greps,
# `ls` and `awk` probes over files that are *expected* to be absent in most
# repos, and a non-zero exit is the normal "this repo has no Makefile" signal.
# Under `-e` the first absent input aborts the run and emits a truncated
# profile that still looks complete -- a silently wrong profile is worse than
# no profile. Failure is handled explicitly instead: every derived field has a
# documented fallback, and thin signals surface as "confidence": "low" with a
# `confidence_reason` that the calling skill is required to read.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/lib/paths.sh"

# ------------------------------------------------------------------ arguments
REPO_DIR=""
DO_WRITE=0
FORCE=0
DATA_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --write) DO_WRITE=1; shift ;;
    --force) FORCE=1; shift ;;
    --data)  DATA_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) REPO_DIR="$1"; shift ;;
  esac
done

if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR" ]; then
  echo "detect-profile.sh: need an existing repo directory" >&2
  echo "usage: detect-profile.sh <repo-dir> [--write] [--force]" >&2
  exit 1
fi

REPO_DIR=$(cd "$REPO_DIR" && pwd -P)
REPO_NAME=$(basename "$REPO_DIR")
PROFILES_DIR="$(k8s_profiles_dir "$DATA_OVERRIDE")"
CACHE="$PROFILES_DIR/$REPO_NAME.json"

# ------------------------------------------------------------------- helpers
have()  { [ -e "$REPO_DIR/$1" ]; }
jstr()  { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'; }
# emit a JSON array from newline-separated stdin
jarray() {
  first=1
  printf '['
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ $first -eq 1 ] || printf ', '
    printf '"%s"' "$(jstr "$line")"
    first=0
  done
  printf ']'
}

# ------------------------------------------------- 0. input fingerprint
# The profile is regenerated when any of the files it was derived from change.
INPUT_FILES="Makefile go.mod go.work .go-version .golangci.yml .golangci.yaml
.prow.yaml OWNERS OWNERS_ALIASES CONTRIBUTING.md"
hash_inputs() {
  {
    for f in $INPUT_FILES; do
      [ -f "$REPO_DIR/$f" ] && cat "$REPO_DIR/$f"
    done
    ls "$REPO_DIR/hack" 2>/dev/null
    ls "$REPO_DIR/.github/workflows" 2>/dev/null
  } 2>/dev/null | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null || cksum; } | awk '{print $1}'
}
INPUT_HASH=$(hash_inputs)

if [ "$DO_WRITE" -eq 1 ] && [ "$FORCE" -eq 0 ] && [ -f "$CACHE" ]; then
  OLD=$(sed -n 's/.*"input_hash"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CACHE" | head -1)
  if [ "$OLD" = "$INPUT_HASH" ]; then
    cat "$CACHE"
    exit 0
  fi
fi

# ------------------------------------------------- 1. Makefile real targets
# Handles multi-target rules ("check test:") and skips pattern/special rules,
# which is why kubernetes/Makefile's `test` target is found at all.
MAKE_TARGETS=""
if have Makefile; then
  MAKE_TARGETS=$(awk '
    /^[[:space:]]/       { next }         # recipe line
    /^[.#]/              { next }         # .PHONY, comments
    /^[^:=]*=/           { next }         # variable assignment
    /^[a-zA-Z0-9_.\/-]+([[:space:]]+[a-zA-Z0-9_.\/-]+)*:/ {
      split($0, parts, ":")
      n = split(parts[1], names, /[[:space:]]+/)
      for (i = 1; i <= n; i++)
        if (names[i] != "" && names[i] !~ /%/ && names[i] !~ /^\./)
          print names[i]
    }' "$REPO_DIR/Makefile" | sort -u)
fi
has_target() { printf '%s\n' "$MAKE_TARGETS" | grep -qx "$1"; }

# --------------------------- Makefile hazards (targets with side effects)
# gwctl: build/test/verify all depend on `deps`, which runs
# `go mod tidy && go mod vendor`. Running them dirties dependency files, which
# the no-new-deps rule forbids. Detect it instead of assuming `make test` is safe.
HAZARDS=""
HAZARD_TARGETS=""
if have Makefile; then
  DEPS_RECIPE=$(awk '/^deps:/{f=1;next} f&&/^[^[:space:]]/{f=0} f' "$REPO_DIR/Makefile" 2>/dev/null)
  if printf '%s' "$DEPS_RECIPE" | grep -Eq 'go +mod +(tidy|vendor)'; then
    for t in build test verify lint all; do
      if awk -v t="$t" '$0 ~ "^"t":"{print}' "$REPO_DIR/Makefile" 2>/dev/null | grep -q 'deps'; then
        HAZARD_TARGETS="$HAZARD_TARGETS $t"
        HAZARDS="$HAZARDS
make $t depends on 'deps', which runs 'go mod tidy && go mod vendor' and rewrites go.mod/go.sum/vendor. guard-deps.sh blocks it. Use the raw go command below instead."
      fi
    done
  fi
fi
# A target that mutates dependency files is not usable as a gate command.
safe_target() {
  has_target "$1" || return 1
  case " $HAZARD_TARGETS " in *" $1 "*) return 1 ;; esac
  return 0
}

# ------------------------------------------------- 2. hack/ script inventory
HACK_VERIFY=""; HACK_UPDATE=""
HAS_INSTALL_ETCD=0; HAS_LOCAL_UP=0; HAS_GINKGO_E2E=0; HAS_CODEGEN=0
if [ -d "$REPO_DIR/hack" ]; then
  HACK_VERIFY=$(ls "$REPO_DIR/hack" 2>/dev/null | grep -E '^verify-.*\.sh$' | head -40)
  HACK_UPDATE=$(ls "$REPO_DIR/hack" 2>/dev/null | grep -E '^update-.*\.sh$' | head -40)
  [ -f "$REPO_DIR/hack/install-etcd.sh" ]     && HAS_INSTALL_ETCD=1
  [ -f "$REPO_DIR/hack/local-up-cluster.sh" ] && HAS_LOCAL_UP=1
  [ -f "$REPO_DIR/hack/ginkgo-e2e.sh" ]       && HAS_GINKGO_E2E=1
  [ -f "$REPO_DIR/hack/update-codegen.sh" ]   && HAS_CODEGEN=1
fi

# ------------------------------------------------- 3. go.mod / go version
MODULE=""; GO_VERSION=""
if have go.mod; then
  MODULE=$(grep -m1 '^module ' "$REPO_DIR/go.mod" | awk '{print $2}')
  GO_VERSION=$(grep -m1 '^go ' "$REPO_DIR/go.mod" | awk '{print $2}')
fi
[ -f "$REPO_DIR/.go-version" ] && GO_VERSION=$(head -1 "$REPO_DIR/.go-version" | tr -d ' \n')

GOLANGCI=""
for f in .golangci.yml .golangci.yaml hack/golangci.yaml hack/golangci.yml; do
  have "$f" && { GOLANGCI="$f"; break; }
done

# ------------------------------------------------- 4. CI config / OWNERS
WORKFLOWS=""
[ -d "$REPO_DIR/.github/workflows" ] && \
  WORKFLOWS=$(ls "$REPO_DIR/.github/workflows" 2>/dev/null | head -20)

# Prow: k/k and most kubernetes-sigs repos are gated by Prow rather than
# GitHub Actions. Signals: an in-repo .prow.yaml, or OWNERS + no workflows.
USES_PROW=false
if have .prow.yaml; then USES_PROW=true
elif have OWNERS && [ -z "$WORKFLOWS" ]; then USES_PROW=true
elif have OWNERS && have SECURITY_CONTACTS; then USES_PROW=true
fi

# OWNERS-derived reviewers: approvers first, then reviewers.
OWNERS_PEOPLE=""
if have OWNERS; then
  OWNERS_PEOPLE=$(awk '
    /^(approvers|reviewers):/ { grab=1; next }
    /^[a-zA-Z]/               { grab=0 }
    grab && /^[[:space:]]*-[[:space:]]*/ {
      gsub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/[[:space:]]*$/, "")
      gsub(/^"/,""); gsub(/"$/,"")
      if ($0 != "" && $0 !~ /^#/) print
    }' "$REPO_DIR/OWNERS" | grep -v '^$' | head -8)
fi

# SIG label: labels: in OWNERS, else infer from the module path.
SIG_LABEL=""
if have OWNERS; then
  SIG_LABEL=$(awk '/^labels:/{grab=1;next} /^[a-zA-Z]/{grab=0} grab' "$REPO_DIR/OWNERS" 2>/dev/null \
              | sed -n 's/.*\(sig\/[a-z-]*\).*/\1/p' | head -1)
fi

# ------------------------------------------------- 5. test layout
TEST_LAYOUT=""
for d in test/integration test/e2e test/e2e_node test/conformance internal pkg cmd staging api; do
  [ -d "$REPO_DIR/$d" ] && TEST_LAYOUT="$TEST_LAYOUT$d
"
done

PR_TEMPLATE=""
for f in .github/PULL_REQUEST_TEMPLATE.md .github/pull_request_template.md \
         docs/PULL_REQUEST_TEMPLATE.md PULL_REQUEST_TEMPLATE.md; do
  have "$f" && { PR_TEMPLATE="$f"; break; }
done

ISSUE_TEMPLATES=""
[ -d "$REPO_DIR/.github/ISSUE_TEMPLATE" ] && \
  ISSUE_TEMPLATES=$(ls "$REPO_DIR/.github/ISSUE_TEMPLATE" 2>/dev/null | head -10)

# ------------------------------------------------- 6. frameworks / libraries
dep_present() { [ -f "$REPO_DIR/go.mod" ] && grep -q "$1" "$REPO_DIR/go.mod"; }

ASSERTION_LIB="stdlib-testing"
# Report the one the repo actually uses most in its own test files -- the fix
# must use that one, not a newly introduced favourite.
if [ -d "$REPO_DIR" ]; then
  N_TESTIFY=$(grep -rl --include='*_test.go' 'stretchr/testify' "$REPO_DIR" 2>/dev/null | head -200 | wc -l | tr -d ' ')
  N_GOMEGA=$(grep -rl  --include='*_test.go' 'onsi/gomega'      "$REPO_DIR" 2>/dev/null | head -200 | wc -l | tr -d ' ')
  N_CMP=$(grep -rl     --include='*_test.go' 'google/go-cmp'    "$REPO_DIR" 2>/dev/null | head -200 | wc -l | tr -d ' ')
  BEST=0
  [ "${N_TESTIFY:-0}" -gt "$BEST" ] && { BEST=$N_TESTIFY; ASSERTION_LIB="stretchr/testify"; }
  [ "${N_GOMEGA:-0}"  -gt "$BEST" ] && { BEST=$N_GOMEGA;  ASSERTION_LIB="onsi/gomega"; }
  [ "${N_CMP:-0}"     -gt "$BEST" ] && { BEST=$N_CMP;     ASSERTION_LIB="google/go-cmp"; }
fi

E2E_FRAMEWORK="none"
if [ -d "$REPO_DIR/test/e2e" ] && dep_present 'onsi/ginkgo'; then E2E_FRAMEWORK="ginkgo"
elif dep_present 'sigs.k8s.io/controller-runtime'; then E2E_FRAMEWORK="envtest"
elif dep_present 'onsi/ginkgo'; then E2E_FRAMEWORK="ginkgo"
fi

USES_ENVTEST=false
dep_present 'controller-runtime' && USES_ENVTEST=true
grep -rqs 'setup-envtest' "$REPO_DIR/Makefile" "$REPO_DIR/hack" 2>/dev/null && USES_ENVTEST=true

NEEDS_ETCD=false
[ "$HAS_INSTALL_ETCD" -eq 1 ] && NEEDS_ETCD=true
# Only real Go source counts. Scanning the whole tree matches etcd strings
# inside testdata/*.json swagger fixtures (kube-openapi) and reports a
# dependency the repo does not actually have.
if [ "$NEEDS_ETCD" = false ] && [ -d "$REPO_DIR/test/integration" ]; then
  if grep -rqs --include='*.go' -e 'go.etcd.io' -e 'etcd3' -e 'EtcdMain' -e 'framework.EtcdMain' \
      "$REPO_DIR/test/integration" 2>/dev/null; then
    NEEDS_ETCD=true
  fi
fi

NEEDS_KIND=false
grep -rqs 'kind create cluster\|kindest/node\|sigs.k8s.io/kind' \
  "$REPO_DIR/Makefile" "$REPO_DIR/hack" "$REPO_DIR/.github" "$REPO_DIR/test" 2>/dev/null && NEEDS_KIND=true

# ------------------------------------------------- commands per gate
# Prefer a real Makefile target; fall back to the plain go toolchain.
if safe_target build;       then CMD_BUILD="make build"
elif safe_target all;       then CMD_BUILD="make all"
else                             CMD_BUILD="go build ./..."; fi
# kubernetes/: `make WHAT=<pkgs>` is the scoped build.
[ "$HAS_CODEGEN" -eq 1 ] && safe_target all && CMD_BUILD="make WHAT=<pkgs>  # or: go build ./..."

if safe_target test;        then CMD_TEST="make test"
else                             CMD_TEST="go test ./..."; fi

if safe_target test;        then CMD_TEST_RACE="make test  # add the repo's race flag"
else                             CMD_TEST_RACE="go test -race -count=1 ./..."; fi
# kubernetes/ has its own race switch
if [ "$HAS_INSTALL_ETCD" -eq 1 ] && safe_target test; then
  CMD_TEST_RACE='make test WHAT=<pkgs> KUBE_RACE=-race GOFLAGS="-count=1"'
elif safe_target test && grep -q 'go test -race' "$REPO_DIR/Makefile" 2>/dev/null; then
  CMD_TEST_RACE="make test"
fi

if has_target test-integration; then CMD_INTEGRATION='make test-integration WHAT=./test/integration/<area> KUBE_TEST_ARGS="-run ^TestX$"'
elif [ -d "$REPO_DIR/test/integration" ]; then CMD_INTEGRATION="go test ./test/integration/... -count=1"
else CMD_INTEGRATION=""; fi

if has_target test-e2e-node; then CMD_E2E_NODE="make test-e2e-node FOCUS=<regex>  # Linux only"
else CMD_E2E_NODE=""; fi

if has_target test-e2e;     then CMD_E2E="make test-e2e"
elif [ "$HAS_GINKGO_E2E" -eq 1 ]; then CMD_E2E="make WHAT=test/e2e/e2e.test && ./_output/bin/e2e.test --provider=local --ginkgo.focus=<regex>"
elif [ -d "$REPO_DIR/test/e2e" ]; then CMD_E2E="go test ./test/e2e/... -count=1"
else CMD_E2E=""; fi

if safe_target verify;      then CMD_VERIFY="make verify"
elif [ -n "$HACK_VERIFY" ]; then CMD_VERIFY="hack/$(printf '%s' "$HACK_VERIFY" | head -1)"
else CMD_VERIFY=""; fi

if safe_target lint;        then CMD_LINT="make lint"
elif [ -n "$GOLANGCI" ];    then CMD_LINT="golangci-lint run"
else CMD_LINT="go vet ./..."; fi

if safe_target update;      then CMD_UPDATE="make update"
elif [ "$HAS_CODEGEN" -eq 1 ]; then CMD_UPDATE="hack/update-codegen.sh"
elif has_target generate;   then CMD_UPDATE="make generate && git diff --exit-code"
else CMD_UPDATE=""; fi

# ------------------------------------------------- gate runtime estimates
# Rough wall-clock, so the verifier can warn before a 40-minute run. Scaled by
# repo size rather than by name.
GO_FILES=$(find "$REPO_DIR" -name '*.go' -not -path '*/vendor/*' 2>/dev/null | head -60000 | wc -l | tr -d ' ')
if   [ "${GO_FILES:-0}" -gt 10000 ]; then SIZE="huge"
elif [ "${GO_FILES:-0}" -gt 1000  ]; then SIZE="large"
elif [ "${GO_FILES:-0}" -gt 100   ]; then SIZE="medium"
else                                      SIZE="small"; fi

case "$SIZE" in
  huge)   EST_BUILD=900; EST_VERIFY=2400; EST_UNIT=1800; EST_INTEG=1200; EST_E2E=3600 ;;
  large)  EST_BUILD=180; EST_VERIFY=600;  EST_UNIT=300;  EST_INTEG=600;  EST_E2E=1800 ;;
  medium) EST_BUILD=30;  EST_VERIFY=90;   EST_UNIT=120;  EST_INTEG=300;  EST_E2E=900 ;;
  *)      EST_BUILD=10;  EST_VERIFY=30;   EST_UNIT=30;   EST_INTEG=60;   EST_E2E=300 ;;
esac

# ------------------------------------------------- sensitive paths
SENSITIVE=""
for d in staging vendor third_party api/openapi-spec pkg/generated \
         pkg/apis staging/src/k8s.io LICENSES; do
  [ -e "$REPO_DIR/$d" ] && SENSITIVE="$SENSITIVE$d
"
done
# generated-file marker sweep (bounded)
if grep -rlsq --include='*.go' 'Code generated by' "$REPO_DIR/pkg" 2>/dev/null; then
  SENSITIVE="$SENSITIVE**/zz_generated.*.go
**/generated.pb.go
"
fi

# ------------------------------------------------- confidence
CONF="high"; CONF_WHY=""
if [ -z "$MODULE" ]; then CONF="low"; CONF_WHY="no go.mod -- this may not be a Go repo"; fi
if [ -z "$MAKE_TARGETS" ] && [ -z "$MODULE" ]; then
  CONF="low"; CONF_WHY="neither a Makefile nor a go.mod was found"
fi
if [ -z "$MAKE_TARGETS" ] && [ -n "$MODULE" ] && [ "$CONF" != "low" ]; then
  CONF="medium"; CONF_WHY="no Makefile: commands fall back to the plain go toolchain"
fi
if [ -z "$CMD_VERIFY" ] && [ "$CONF" = "high" ]; then
  CONF="medium"; CONF_WHY="no verify target or hack/verify-*.sh found; G1 has no repo-native command"
fi

# ------------------------------------------------- change-class gate map
# (build spec section 4 "Gate selection"). Emitted per profile so the verifier
# does not have to re-derive it.
GATEMAP='{
    "unit-logic":        ["G0","G1","G2","G3","G4","G10"],
    "controller":        ["G0","G1","G2","G3","G4","G5","G10"],
    "api-type":          ["G0","G1","G2","G3","G4","G5","G9","G10"],
    "kubelet-node":      ["G0","G1","G2","G3","G4","G6","G10"],
    "scheduler":         ["G0","G1","G2","G3","G4","G5","G10"],
    "flake":             ["G0","G1","G2","G3","G4","G7","G10"],
    "cli-tool":          ["G0","G1","G2","G3","G4","G6","G10"],
    "docs-only":         ["G0","G1","G4","G9"]
  }'

# ------------------------------------------------------------------ emit
OUT=$(cat <<JSON
{
  "schema": "k8s-agent-profile/v1",
  "repo": "$(jstr "$REPO_NAME")",
  "path": "$(jstr "$REPO_DIR")",
  "module": "$(jstr "$MODULE")",
  "go_version": "$(jstr "$GO_VERSION")",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "input_hash": "$(jstr "$INPUT_HASH")",
  "confidence": "$CONF",
  "confidence_reason": "$(jstr "$CONF_WHY")",
  "size_class": "$SIZE",
  "go_file_count": ${GO_FILES:-0},

  "commands": {
    "build":       "$(jstr "$CMD_BUILD")",
    "test":        "$(jstr "$CMD_TEST")",
    "test_race":   "$(jstr "$CMD_TEST_RACE")",
    "integration": "$(jstr "$CMD_INTEGRATION")",
    "e2e":         "$(jstr "$CMD_E2E")",
    "e2e_node":    "$(jstr "$CMD_E2E_NODE")",
    "verify":      "$(jstr "$CMD_VERIFY")",
    "lint":        "$(jstr "$CMD_LINT")",
    "update_generated": "$(jstr "$CMD_UPDATE")"
  },

  "make_targets": $(printf '%s\n' "$MAKE_TARGETS" | jarray),
  "hack_verify_scripts": $(printf '%s\n' "$HACK_VERIFY" | jarray),
  "hack_update_scripts": $(printf '%s\n' "$HACK_UPDATE" | jarray),

  "requires": {
    "etcd":    $NEEDS_ETCD,
    "kind":    $NEEDS_KIND,
    "envtest": $USES_ENVTEST
  },
  "etcd_setup": $( [ "$HAS_INSTALL_ETCD" -eq 1 ] \
      && printf '"hack/install-etcd.sh && export PATH=$PATH:%s/third_party/etcd"' "$(jstr "$REPO_DIR")" \
      || printf 'null' ),

  "e2e_framework": "$E2E_FRAMEWORK",
  "assertion_library": "$ASSERTION_LIB",
  "test_file_convention": "*_test.go, table-driven; see contributor coding-conventions.md",
  "test_layout": $(printf '%s\n' "$TEST_LAYOUT" | jarray),

  "pr_template": $( [ -n "$PR_TEMPLATE" ] && printf '"%s"' "$(jstr "$PR_TEMPLATE")" || printf 'null' ),
  "issue_templates": $(printf '%s\n' "$ISSUE_TEMPLATES" | jarray),
  "github_workflows": $(printf '%s\n' "$WORKFLOWS" | jarray),
  "uses_prow": $USES_PROW,
  "owners_reviewers": $(printf '%s\n' "$OWNERS_PEOPLE" | jarray),
  "sig_label": $( [ -n "$SIG_LABEL" ] && printf '"%s"' "$(jstr "$SIG_LABEL")" || printf 'null' ),
  "golangci_config": $( [ -n "$GOLANGCI" ] && printf '"%s"' "$(jstr "$GOLANGCI")" || printf 'null' ),

  "sensitive_paths": $(printf '%s\n' "$SENSITIVE" | jarray),
  "hazards": $(printf '%s\n' "$HAZARDS" | jarray),

  "gate_runtime_estimate_s": {
    "G0_build": $EST_BUILD,
    "G1_verify": $EST_VERIFY,
    "G3_unit_race": $EST_UNIT,
    "G5_integration": $EST_INTEG,
    "G6_e2e": $EST_E2E
  },

  "gate_sets_by_change_class": $GATEMAP
}
JSON
)

# Pretty-print through jq when available; it also validates the JSON we built.
if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$OUT" | jq . >/dev/null 2>&1; then
    echo "detect-profile.sh: generated invalid JSON for $REPO_NAME" >&2
    printf '%s\n' "$OUT" >&2
    exit 1
  fi
  OUT=$(printf '%s' "$OUT" | jq .)
fi

if [ "$DO_WRITE" -eq 1 ]; then
  mkdir -p "$(dirname "$CACHE")"
  printf '%s\n' "$OUT" > "$CACHE"
  echo "# cached to $CACHE" >&2
fi

printf '%s\n' "$OUT"

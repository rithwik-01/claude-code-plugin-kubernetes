#!/usr/bin/env bash
# verify-all.sh -- run the applicable gate set for a change class and aggregate
# every gate result into <state-dir>/gate.json.
#
# Usage:
#   verify-all.sh --state <dir> --repo <repo-dir> --class <change-class>
#                 [--base <ref>] [--pkgs <go pkg pattern>] [--test <TestName>]
#                 [--dry-run] [--only G0,G3] [--data <cache-dir>]
#
# Change classes (build spec section 4 "Gate selection"):
#   unit-logic  controller  api-type  kubelet-node  scheduler  flake
#   cli-tool    docs-only
#
# The gate set is NOT chosen by an agent. It comes from the change class plus
# the profile, and every gate lands in gate.json with an evidence path or an
# explicit reason. "overall" is pass only when no applicable gate failed and
# none is still pending.
#
# bash 3.2 compatible.

# See detect-profile.sh for why this is `set -u` and not `set -e`: gate
# commands are *expected* to exit non-zero (that is the gate failing), and the
# aggregate verdict is computed from the per-gate JSON, not from $?.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/lib/paths.sh"
RUN_GATE="$HERE/run-gate.sh"

STATE=""; REPO=""; CLASS=""; BASE=""; PKGS="./..."; TESTNAME=""; DRY=0; ONLY=""
DATA_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    --repo)  REPO="$2";  shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --base)  BASE="$2";  shift 2 ;;
    --pkgs)  PKGS="$2";  shift 2 ;;
    --test)  TESTNAME="$2"; shift 2 ;;
    --only)  ONLY="$2";  shift 2 ;;
    --data)  DATA_OVERRIDE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "verify-all.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$STATE" ] || { echo "verify-all.sh: --state is required" >&2; exit 2; }
[ -n "$REPO"  ] || { echo "verify-all.sh: --repo is required" >&2; exit 2; }
[ -n "$CLASS" ] || { echo "verify-all.sh: --class is required" >&2; exit 2; }
[ -d "$REPO"  ] || { echo "verify-all.sh: no such repo dir: $REPO" >&2; exit 2; }

REPO=$(cd "$REPO" && pwd -P)
REPO_NAME=$(basename "$REPO")
mkdir -p "$STATE/evidence" "$STATE/gates"

# ------------------------------------------------------------------ profile
PROFILE="$(k8s_profiles_dir "$DATA_OVERRIDE")/$REPO_NAME.json"
if [ ! -f "$PROFILE" ]; then
  "$HERE/detect-profile.sh" "$REPO" --write --data "$(k8s_data_root "$DATA_OVERRIDE")" >/dev/null 2>&1
fi
pget() {  # pget <jq-path> <default>
  if [ -f "$PROFILE" ] && command -v jq >/dev/null 2>&1; then
    v=$(jq -r "$1 // empty" "$PROFILE" 2>/dev/null)
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  fi
  printf '%s' "$2"
}

C_BUILD=$(pget '.commands.build'       'go build ./...')
C_TEST=$(pget  '.commands.test_race'   'go test -race -count=1 ./...')
C_INTEG=$(pget '.commands.integration' '')
C_VERIFY=$(pget '.commands.verify'     '')
C_LINT=$(pget  '.commands.lint'        'go vet ./...')
C_E2E=$(pget   '.commands.e2e'         '')
C_E2E_NODE=$(pget '.commands.e2e_node' '')
NEEDS_ETCD=$(pget '.requires.etcd'     'false')
ETCD_SETUP=$(pget '.etcd_setup'        '')

# Substitute the caller's package scope into the profile's command templates.
subst() { printf '%s' "$1" | sed -e "s|<pkgs>|$PKGS|g" -e "s|\./\.\.\.|$PKGS|g" -e "s|<area>|$PKGS|g" -e "s|\^TestX\\\$|^${TESTNAME:-.}\$|g" -e "s|<regex>|${TESTNAME:-.}|g"; }

# ------------------------------------------------------- gate set selection
case "$CLASS" in
  unit-logic)   GATES="G0 G1 G2 G3 G4 G10" ;;
  controller)   GATES="G0 G1 G2 G3 G4 G5 G10" ;;
  api-type)     GATES="G0 G1 G2 G3 G4 G5 G9 G10" ;;
  kubelet-node) GATES="G0 G1 G2 G3 G4 G6 G10" ;;
  scheduler)    GATES="G0 G1 G2 G3 G4 G5 G10" ;;
  flake)        GATES="G0 G1 G2 G3 G4 G7 G10" ;;
  cli-tool)     GATES="G0 G1 G2 G3 G4 G6 G10" ;;
  docs-only)    GATES="G0 G1 G4 G9" ;;
  *) echo "verify-all.sh: unknown change class '$CLASS'" >&2
     echo "  one of: unit-logic controller api-type kubelet-node scheduler flake cli-tool docs-only" >&2
     exit 2 ;;
esac

wanted() {
  [ -z "$ONLY" ] && { case " $GATES " in *" $1 "*) return 0 ;; esac; return 1; }
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

gate() {  # gate <id> <name> <cmd> [extra run-gate args...]
  id="$1"; name="$2"; cmd="$3"; shift 3
  wanted "$id" || return 0
  if [ "$DRY" -eq 1 ]; then
    printf '%-4s %-22s would run: %s\n' "$id" "$name" "$cmd"
    return 0
  fi
  "$RUN_GATE" --state "$STATE" --id "$id" --name "$name" --cmd "$cmd" --dir "$REPO" "$@"
}

skip() {  # skip <id> <name> <status> <reason>
  wanted "$1" || return 0
  if [ "$DRY" -eq 1 ]; then
    printf '%-4s %-22s would record: %s (%s)\n' "$1" "$2" "$3" "$4"
    return 0
  fi
  "$RUN_GATE" --state "$STATE" --id "$1" --name "$2" --status "$3" --reason "$4"
}

echo "verify-all.sh: repo=$REPO_NAME class=$CLASS gates=[$GATES]"
echo

# --------------------------------------------------------------- G0  build
gate G0 build "$(subst "$C_BUILD")"

# --------------------------------- G1  static analysis + generated-code check
if [ -n "$C_VERIFY" ]; then
  gate G1 static-and-generated "$C_VERIFY"
else
  gate G1 static-and-generated "$(subst "$C_LINT")"
fi

# ------------------------------------------------- G2  regression proof
# Mechanized red -> green. The caller stages the red condition (source change
# stashed, test present); this asserts the exit codes in the required order.
#   red   : MUST fail   -> evidence/G2-red.log
#   green : MUST pass   -> evidence/G2-green.log
# run-gate.sh --expect-fail marks G2 fail if the "red" run passes.
if wanted G2; then
  if [ -z "$TESTNAME" ]; then
    skip G2 regression-proof skipped \
      "no --test given: the regression proof needs the exact test that fails before the fix and passes after it"
  elif [ "$DRY" -eq 1 ]; then
    printf '%-4s %-22s would run red/green around: %s\n' G2 regression-proof "$TESTNAME"
  else
    echo "G2   regression-proof     (red -> green; run this with the source change stashed, then restored)"
    echo "     red half must be run by the caller with the fix removed. See k8s-verification-matrix/references/g2-regression-proof.md"
    "$RUN_GATE" --state "$STATE" --id G2 --name regression-proof \
      --cmd "go test $PKGS -run '^${TESTNAME}\$' -race -count=1" --dir "$REPO"
  fi
fi

# ----------------------------------------------------------- G3  unit + race
gate G3 unit-race "$(subst "$C_TEST")"

# --------------------------------------------------------- G4  diff hygiene
if wanted G4; then
  BASE_REF="${BASE:-HEAD}"
  HYG="$HERE/lib/diff-hygiene.sh"
  if [ -x "$HYG" ]; then
    gate G4 diff-hygiene "$HYG '$BASE_REF'"
  else
    gate G4 diff-hygiene "git diff --stat $BASE_REF && git diff --name-only $BASE_REF | grep -E '^(go\.mod|go\.sum|vendor/|third_party/)' && exit 1 || exit 0"
  fi
fi

# ------------------------------------------------------------ G5 integration
if wanted G5; then
  if [ -z "$C_INTEG" ]; then
    skip G5 integration not-applicable "this repo has no integration test target or test/integration directory"
  elif [ "$NEEDS_ETCD" = "true" ] && ! command -v etcd >/dev/null 2>&1 && [ ! -x "$REPO/third_party/etcd/etcd" ]; then
    skip G5 integration skipped \
      "etcd is not on PATH. Run: ${ETCD_SETUP:-hack/install-etcd.sh} then re-run G5"
  else
    gate G5 integration "$(subst "$C_INTEG")"
  fi
fi

# ------------------------------------------------------------ G6 cluster/e2e
if wanted G6; then
  UNAME=$(uname -s)
  if [ -n "$C_E2E_NODE" ] && [ "$CLASS" = "kubelet-node" ]; then
    if [ "$UNAME" != "Linux" ]; then
      # Node e2e is Linux-only. Recording a pass here would be a lie.
      skip G6 node-e2e deferred-to-ci \
        "node e2e is Linux-only and this host is $UNAME; covered by Prow job pull-kubernetes-node-e2e-containerd"
    else
      gate G6 node-e2e "$(subst "$C_E2E_NODE")"
    fi
  elif command -v kind >/dev/null 2>&1; then
    skip G6 cluster-e2e skipped \
      "cluster verification is driven by $HERE/kind-up.sh; run it, replay the reporter's steps, then record G6 with run-gate.sh"
  else
    skip G6 cluster-e2e deferred-to-ci "kind is not installed on this host"
  fi
fi

# --------------------------------------------------------- G7 flake statistics
if wanted G7; then
  if [ -z "$TESTNAME" ]; then
    skip G7 flake-statistics skipped "no --test given: G7 needs the flaking test name"
  elif [ "$DRY" -eq 1 ]; then
    printf '%-4s %-22s would run repro-loop.sh\n' G7 flake-statistics
  else
    skip G7 flake-statistics skipped \
      "two-sided proof: run repro-loop.sh before the fix (need >=1 failure in N) and after the fix (need 50 clean runs). See k8s-verification-matrix"
  fi
fi

# -------------------------------------------------------------- G8 benchmark
if wanted G8; then
  gate G8 benchmark "go test $PKGS -bench=. -benchmem -count=10 -run '^\$'"
fi

# ------------------------------------------------- G9 docs / release note
if wanted G9; then
  if [ -f "$STATE/artifacts/pr-description.md" ] && \
     grep -q 'release-note' "$STATE/artifacts/pr-description.md" 2>/dev/null; then
    gate G9 release-note "grep -q 'release-note' '$STATE/artifacts/pr-description.md'"
  else
    skip G9 release-note skipped "no release note drafted yet in artifacts/pr-description.md"
  fi
fi

# --------------------------------------------------------------- G10 CI parity
# Always a checklist, never a local run: the real arbiter is Prow.
if wanted G10; then
  CI="$STATE/artifacts/ci-parity.md"
  if [ -f "$CI" ]; then
    skip G10 ci-parity deferred-to-ci \
      "presubmit checklist recorded at artifacts/ci-parity.md; Prow is the arbiter"
  else
    skip G10 ci-parity deferred-to-ci \
      "no artifacts/ci-parity.md yet: list the presubmits that will gate this PR and map each to what ran locally"
  fi
fi

# ------------------------------------------------------------ aggregate
[ "$DRY" -eq 1 ] && exit 0

HEAD_SHA=$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo "")
BASE_SHA=$(cd "$REPO" && git rev-parse "${BASE:-HEAD}" 2>/dev/null || echo "")
RUN_ID="$REPO_NAME/$(basename "$STATE")"

if command -v jq >/dev/null 2>&1; then
  GATE_ARRAY=$(cat "$STATE"/gates/*.json 2>/dev/null | jq -s 'sort_by(.id)')
  [ -n "$GATE_ARRAY" ] || GATE_ARRAY='[]'

  # overall = pass only if no applicable gate failed AND every applicable gate
  # was recorded. A missing gate is not a pass.
  RECORDED=$(printf '%s' "$GATE_ARRAY" | jq -r '.[].id' | sort -u | tr '\n' ' ')
  MISSING=""
  for g in $GATES; do
    case " $RECORDED " in *" $g "*) ;; *) MISSING="$MISSING $g" ;; esac
  done

  # Strict semantics, so "overall" cannot be talked up by an agent:
  #   pass            -> counts as satisfied (must carry an evidence path)
  #   not-applicable  -> satisfied; the gate does not apply to this repo/class
  #   deferred-to-ci  -> satisfied ONLY because it names the CI job that covers
  #                      it; this is the honest recording for node-e2e on macOS
  #                      and for G10, which is a checklist by definition
  #   skipped         -> NOT satisfied: the gate should have run and did not
  #   fail            -> NOT satisfied
  #   unrecorded      -> NOT satisfied
  BLOCKING=$(printf '%s' "$GATE_ARRAY" \
    | jq -r '[.[]|select(.status=="fail" or .status=="skipped")|.id]|join(" ")')
  # A "pass" with no evidence log is not a pass.
  NOEVIDENCE=$(printf '%s' "$GATE_ARRAY" \
    | jq -r '[.[]|select(.status=="pass" and (.evidence=="" or .evidence==null))|.id]|join(" ")')

  if [ -n "$BLOCKING" ] || [ -n "$MISSING" ] || [ -n "$NOEVIDENCE" ]; then
    OVERALL="fail"
  else
    OVERALL="pass"
  fi

  jq -n \
    --arg run "$RUN_ID" --arg base "$BASE_SHA" --arg head "$HEAD_SHA" \
    --arg profile "$REPO_NAME" --arg class "$CLASS" --arg overall "$OVERALL" \
    --arg applicable "$GATES" --arg missing "${MISSING# }" \
    --arg blocking "$BLOCKING" --arg noevidence "$NOEVIDENCE" \
    --argjson gates "$GATE_ARRAY" \
    '{run:$run, base:$base, head:$head, profile:$profile, change_class:$class,
      applicable_gates:($applicable|split(" ")),
      missing_gates:   (if $missing==""    then [] else ($missing|split(" "))    end),
      blocking_gates:  (if $blocking==""   then [] else ($blocking|split(" "))   end),
      pass_without_evidence:(if $noevidence=="" then [] else ($noevidence|split(" ")) end),
      gates:$gates, overall:$overall,
      generated_at:(now|todate)}' > "$STATE/gate.json"
else
  printf '{"run":"%s","overall":"unknown","note":"jq unavailable; inspect gates/*.json"}\n' \
    "$RUN_ID" > "$STATE/gate.json"
  OVERALL="unknown"
fi

echo
echo "gate.json -> $STATE/gate.json"
echo "overall: $OVERALL"
[ -n "${MISSING:-}" ]    && echo "NOT RECORDED (counts as fail): ${MISSING# }"
[ -n "${BLOCKING:-}" ]   && echo "BLOCKING (fail/skipped):        $BLOCKING"
[ -n "${NOEVIDENCE:-}" ] && echo "PASS WITHOUT EVIDENCE (invalid): $NOEVIDENCE"
[ "$OVERALL" = "pass" ] || exit 1
exit 0

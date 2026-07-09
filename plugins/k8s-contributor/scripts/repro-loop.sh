#!/usr/bin/env bash
# repro-loop.sh -- G7. Statistical flake reproduction / confirmation.
#
# A flake has no single deterministic repro, so the pass criterion is
# statistical and TWO-SIDED (build spec section 4, G7):
#
#   before the fix : run N times, require >= 1 failure  -> flake reproduced
#   after  the fix : run M times clean, require 0 failures
#
# If the flake cannot be reproduced locally, DO NOT guess a fix. This script
# exits 3 in that case so the caller reports `insufficient-info` and proposes
# an instrumentation-only PR instead.
#
# Usage:
#   repro-loop.sh --dir <repo> --pkg ./test/integration/foo --test '^TestBar$'
#                 [--runs 20] [--mode reproduce|confirm] [--state <dir>]
#                 [--load] [--gomaxprocs "1 2 4 8"] [--timeout 10m]
#
#   --mode reproduce  (default) expect >=1 failure in N runs
#   --mode confirm    expect 0 failures in N runs (default N=50 in this mode)
#   --load            run a CPU-contention generator alongside, which is what
#                     surfaces most timing flakes
#
# Exit: 0 = criterion met, 1 = criterion not met, 3 = could not reproduce.
# bash 3.2 compatible.

set -u

DIR="."; PKG=""; TEST=""; RUNS=""; MODE="reproduce"; STATE=""
LOAD=0; GOMAXPROCS_LIST="1 2 4 8"; TIMEOUT="10m"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)  DIR="$2"; shift 2 ;;
    --pkg)  PKG="$2"; shift 2 ;;
    --test) TEST="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --load) LOAD=1; shift ;;
    --gomaxprocs) GOMAXPROCS_LIST="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "repro-loop.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$PKG" ]  || { echo "repro-loop.sh: --pkg is required" >&2; exit 2; }
[ -n "$TEST" ] || { echo "repro-loop.sh: --test is required" >&2; exit 2; }
[ -d "$DIR" ]  || { echo "repro-loop.sh: no such dir: $DIR" >&2; exit 2; }

case "$MODE" in
  reproduce) [ -n "$RUNS" ] || RUNS=20 ;;
  confirm)   [ -n "$RUNS" ] || RUNS=50 ;;
  *) echo "repro-loop.sh: --mode must be reproduce|confirm" >&2; exit 2 ;;
esac

DIR=$(cd "$DIR" && pwd -P)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
if [ -n "$STATE" ]; then
  OUTDIR="$STATE/evidence/repro-$MODE-$STAMP"
else
  OUTDIR="$DIR/.repro-$MODE-$STAMP"
fi
mkdir -p "$OUTDIR"

echo "repro-loop.sh"
echo "  repo:       $DIR"
echo "  package:    $PKG"
echo "  test:       $TEST"
echo "  mode:       $MODE"
echo "  runs:       $RUNS"
echo "  gomaxprocs: $GOMAXPROCS_LIST"
echo "  cpu load:   $( [ "$LOAD" -eq 1 ] && echo yes || echo no )"
echo "  evidence:   $OUTDIR"
echo

# ------------------------------------------------------------- optional load
LOAD_PIDS=""
start_load() {
  [ "$LOAD" -eq 1 ] || return 0
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  i=0
  while [ "$i" -lt "$n" ]; do
    ( while :; do :; done ) & LOAD_PIDS="$LOAD_PIDS $!"
    i=$((i+1))
  done
  echo "  started $n CPU-contention workers ($LOAD_PIDS)"
}
stop_load() {
  [ -n "$LOAD_PIDS" ] || return 0
  kill $LOAD_PIDS 2>/dev/null
  wait $LOAD_PIDS 2>/dev/null
  LOAD_PIDS=""
}
trap 'stop_load; exit 130' INT TERM
start_load

# ------------------------------------------------------------------ the loop
FAILURES=0
PASSES=0
FAILED_RUNS=""
i=1
while [ "$i" -le "$RUNS" ]; do
  # rotate GOMAXPROCS across the configured values -- scheduling pressure is
  # what most timing flakes actually depend on
  set -- $GOMAXPROCS_LIST
  idx=$(( (i - 1) % $# + 1 ))
  eval "GMP=\${$idx}"

  LOG="$OUTDIR/run-$(printf '%03d' "$i")-gomaxprocs$GMP.log"
  ( cd "$DIR" && GOMAXPROCS="$GMP" \
      go test "$PKG" -run "$TEST" -race -count=1 -timeout "$TIMEOUT" -v ) \
      > "$LOG" 2>&1
  RC=$?

  if [ "$RC" -eq 0 ]; then
    PASSES=$((PASSES+1)); printf '.'
  else
    FAILURES=$((FAILURES+1)); FAILED_RUNS="$FAILED_RUNS $i"; printf 'F'
  fi
  # keep the line readable
  [ $((i % 50)) -eq 0 ] && printf ' %s/%s\n' "$i" "$RUNS"
  i=$((i+1))
done
printf '\n\n'
stop_load

RATE=$(awk -v f="$FAILURES" -v n="$RUNS" 'BEGIN{ printf "%.1f", (n>0 ? 100*f/n : 0) }')

# ------------------------------------------------------------------ summary
SUMMARY="$OUTDIR/summary.json"
cat > "$SUMMARY" <<JSON
{
  "mode": "$MODE",
  "package": "$PKG",
  "test": "$TEST",
  "runs": $RUNS,
  "failures": $FAILURES,
  "passes": $PASSES,
  "failure_rate_pct": $RATE,
  "failed_run_indexes": "$(printf '%s' "${FAILED_RUNS# }")",
  "gomaxprocs_rotation": "$GOMAXPROCS_LIST",
  "cpu_load": $( [ "$LOAD" -eq 1 ] && echo true || echo false ),
  "race_detector": true,
  "evidence_dir": "$OUTDIR",
  "recorded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

echo "runs=$RUNS  failures=$FAILURES  passes=$PASSES  failure_rate=${RATE}%"
echo "summary: $SUMMARY"
[ -n "$FAILED_RUNS" ] && echo "failing run logs:$(printf ' %s' $FAILED_RUNS)"
echo

if [ "$MODE" = "reproduce" ]; then
  if [ "$FAILURES" -ge 1 ]; then
    echo "G7 reproduce: PASS -- flake reproduced ($FAILURES/$RUNS)."
    echo "Now find the ROOT CAUSE. Raising a timeout, adding a sleep, adding a"
    echo "retry, or tagging the test [Flaky] are blocker-severity workarounds."
    exit 0
  fi
  echo "G7 reproduce: NOT REPRODUCED (0/$RUNS)."
  echo
  echo "Do NOT guess a fix. The correct output is 'insufficient-info':"
  echo "  - attach the CI evidence from the issue (Testgrid / go.k8s.io/triage / Prow logs)"
  echo "  - consider proposing an instrumentation-only PR that would capture the"
  echo "    missing state the next time CI hits it"
  echo "  - or raise N (--runs), add --load, or widen --gomaxprocs and retry"
  exit 3
fi

# confirm
if [ "$FAILURES" -eq 0 ]; then
  echo "G7 confirm: PASS -- $RUNS consecutive clean runs with -race."
  echo "Pair this with the pre-fix reproduction summary to make the two-sided proof."
  exit 0
fi
echo "G7 confirm: FAIL -- still flaking ($FAILURES/$RUNS). The root cause is not fixed."
exit 1

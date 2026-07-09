#!/usr/bin/env bash
# run-gate.sh -- run ONE verification gate, capture evidence, emit a result JSON.
#
# The gate result is decided by the exit code of a real command, written to a
# real log file. Nothing here takes an agent's word for it.
#
# Usage:
#   run-gate.sh --state <dir> --id G3 --name unit-race --cmd '<shell command>'
#               [--dir <workdir>] [--expect-fail] [--timeout <s>]
#               [--status skipped|deferred-to-ci|not-applicable --reason '<why>']
#
#   --expect-fail   invert the pass condition: the command MUST exit non-zero.
#                   This is how G2's "red" half is proven (a test that passes
#                   without the fix proves nothing).
#   --status        record a gate without running it. A reason is REQUIRED --
#                   a skipped gate with no reason is itself a failure.
#
# Writes:
#   <state>/evidence/<id>-<name>.log      full stdout+stderr
#   <state>/gates/<id>.json               one gate object (see gate.json schema)
#
# Exit: 0 if the gate passed, 1 if it failed. bash 3.2 compatible.

set -u

STATE=""; ID=""; NAME=""; CMD=""; WORKDIR=""; EXPECT_FAIL=0
FORCED_STATUS=""; REASON=""; TIMEOUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --state)       STATE="$2"; shift 2 ;;
    --id)          ID="$2"; shift 2 ;;
    --name)        NAME="$2"; shift 2 ;;
    --cmd)         CMD="$2"; shift 2 ;;
    --dir)         WORKDIR="$2"; shift 2 ;;
    --expect-fail) EXPECT_FAIL=1; shift ;;
    --timeout)     TIMEOUT="$2"; shift 2 ;;
    --status)      FORCED_STATUS="$2"; shift 2 ;;
    --reason)      REASON="$2"; shift 2 ;;
    -h|--help)     sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "run-gate.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$STATE" ] || { echo "run-gate.sh: --state is required" >&2; exit 2; }
[ -n "$ID" ]    || { echo "run-gate.sh: --id is required" >&2; exit 2; }
[ -n "$NAME" ]  || NAME="$ID"

mkdir -p "$STATE/evidence" "$STATE/gates"
LOG_REL="evidence/${ID}-${NAME}.log"
LOG="$STATE/$LOG_REL"

jstr() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'; }

emit() {   # emit <status> <exit_code> <duration> <evidence-or-empty>
  cat > "$STATE/gates/$ID.json" <<JSON
{
  "id": "$(jstr "$ID")",
  "name": "$(jstr "$NAME")",
  "status": "$1",
  "command": "$(jstr "$CMD")",
  "exit_code": $2,
  "expect_fail": $( [ "$EXPECT_FAIL" -eq 1 ] && echo true || echo false ),
  "evidence": "$(jstr "$4")",
  "reason": "$(jstr "$REASON")",
  "duration_s": $3,
  "workdir": "$(jstr "${WORKDIR:-$PWD}")",
  "recorded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
  printf '%-4s %-22s %s%s\n' "$ID" "$NAME" "$1" \
    "$( [ -n "$REASON" ] && printf '  (%s)' "$REASON" )"
}

# ------------------------------------------- not-run gates (must give a reason)
if [ -n "$FORCED_STATUS" ]; then
  case "$FORCED_STATUS" in
    skipped|deferred-to-ci|not-applicable) ;;
    *) echo "run-gate.sh: --status must be skipped|deferred-to-ci|not-applicable" >&2; exit 2 ;;
  esac
  if [ -z "$REASON" ]; then
    echo "run-gate.sh: --status $FORCED_STATUS requires --reason." >&2
    echo "  A gate that did not run must say why, and 'deferred-to-ci' must name the CI job." >&2
    exit 2
  fi
  emit "$FORCED_STATUS" 0 0 ""
  # Not-run gates are not failures, but they are not passes either.
  exit 0
fi

[ -n "$CMD" ] || { echo "run-gate.sh: --cmd is required unless --status is given" >&2; exit 2; }

# ----------------------------------------------------------------- execute
START=$(date +%s)
{
  echo "### gate:     $ID ($NAME)"
  echo "### command:  $CMD"
  echo "### workdir:  ${WORKDIR:-$PWD}"
  echo "### expect:   $( [ "$EXPECT_FAIL" -eq 1 ] && echo 'NON-ZERO exit (red half of the regression proof)' || echo 'zero exit' )"
  echo "### started:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "###"
} > "$LOG"

RUN_CMD="$CMD"
if [ -n "$TIMEOUT" ] && command -v timeout >/dev/null 2>&1; then
  RUN_CMD="timeout $TIMEOUT $CMD"
fi

if [ -n "$WORKDIR" ]; then
  ( cd "$WORKDIR" && eval "$RUN_CMD" ) >> "$LOG" 2>&1
  RC=$?
else
  ( eval "$RUN_CMD" ) >> "$LOG" 2>&1
  RC=$?
fi

END=$(date +%s)
DUR=$((END - START))

{
  echo "###"
  echo "### exit_code: $RC"
  echo "### duration:  ${DUR}s"
  echo "### finished:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$LOG"

# ------------------------------------------------------------- pass/fail
if [ "$EXPECT_FAIL" -eq 1 ]; then
  # The red half of G2. A zero exit here means the test passes WITHOUT the
  # fix, so it is not a regression test at all.
  if [ "$RC" -ne 0 ]; then
    emit "pass" "$RC" "$DUR" "$LOG_REL"
    exit 0
  else
    REASON="command SUCCEEDED but was expected to fail: the test passes without the fix, so it does not prove the regression"
    emit "fail" "$RC" "$DUR" "$LOG_REL"
    exit 1
  fi
fi

if [ "$RC" -eq 0 ]; then
  emit "pass" "$RC" "$DUR" "$LOG_REL"
  exit 0
else
  [ -n "$REASON" ] || REASON="command exited $RC; see $LOG_REL"
  emit "fail" "$RC" "$DUR" "$LOG_REL"
  exit 1
fi

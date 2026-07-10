#!/usr/bin/env bash
# prove-guardrails.sh -- prove the approval guarantee survives the repackaging.
#
# A plugin cannot ship permission rules, so the guarantee rests entirely on
# hooks/scripts/guard-destructive.sh. This script proves that by running the
# hook against a scratch project directory with NO permissions.deny configured
# anywhere, feeding it the exact commands the guarantee names.
#
# Usage: prove-guardrails.sh [--guard <path-to-guard-destructive.sh>]
#        (defaults to the installed plugin, falling back to this repo's copy)
#
# Exit 0 = every case behaved as specified, 1 otherwise. Run in CI.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
CASES="$HERE/guardrail-cases.txt"
GUARD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --guard) GUARD="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "prove-guardrails.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$GUARD" ]; then
  INSTALLED=$(ls -d "$HOME"/.claude/plugins/cache/*/k8s-contributor/*/hooks/scripts/guard-destructive.sh 2>/dev/null | tail -1)
  if [ -n "$INSTALLED" ]; then
    GUARD="$INSTALLED"
  else
    GUARD="$HERE/../plugins/k8s-contributor/hooks/scripts/guard-destructive.sh"
  fi
fi

[ -f "$GUARD" ]  || { echo "no guard script at $GUARD" >&2; exit 2; }
[ -f "$CASES" ]  || { echo "no case list at $CASES" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

# A scratch project with no settings at all: no deny rules, no allow rules.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/k8s-guardrail.XXXXXX")
mkdir -p "$SCRATCH/.claude"
trap 'rm -rf "$SCRATCH"' EXIT

echo "guard   : $GUARD"
echo "scratch : $SCRATCH"
echo "settings: $(find "$SCRATCH/.claude" -type f | wc -l | tr -d ' ') files  ->  NO deny rules configured"
echo

PASS=0; FAIL=0; MODE=""
while IFS='|' read -r want cmd; do
  [ -n "${want:-}" ] || continue
  case "$want" in \#*) continue ;; esac
  if [ "$want" != "$MODE" ]; then
    MODE="$want"
    echo
    if [ "$MODE" = BLOCK ]; then echo "######## MUST BLOCK (exit 2) ########"
    else echo "######## MUST ALLOW (exit 0) ########"; fi
  fi
  payload=$(jq -nc --arg c "$cmd" --arg d "$SCRATCH" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')
  out=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$SCRATCH" "$GUARD" 2>&1)
  rc=$?
  if [ "$MODE" = BLOCK ]; then wantrc=2; else wantrc=0; fi
  if [ "$rc" -eq "$wantrc" ]; then
    PASS=$((PASS+1)); printf '  ok    exit=%s  %s\n' "$rc" "$cmd"
    if [ "$MODE" = BLOCK ]; then
      printf '        %s\n' "$(printf '%s' "$out" | grep -m1 '^Reason:' | cut -c1-96)"
    fi
  else
    FAIL=$((FAIL+1)); printf '  FAIL  exit=%s want=%s  %s\n' "$rc" "$wantrc" "$cmd"
  fi
done < "$CASES"

echo
echo "======== summary ========"
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo
echo "The approval guarantee holds with no permission rules configured."

#!/usr/bin/env bash
# merge-deny.sh -- show, and only on request apply, the recommended
# permissions.deny block in a settings.json.
#
#   merge-deny.sh --target <settings.json> [--apply]
#
# Without --apply it PRINTS THE DIFF AND WRITES NOTHING. That is the default
# on purpose: this edits the user's own configuration, so it is their call.
#
# The deny block is defense-in-depth only. A plugin cannot ship permission
# rules (a plugin settings.json honors just `agent` and `subagentStatusLine`),
# so the real enforcement is hooks/scripts/guard-destructive.sh, which is
# always active whether or not this block exists.
#
# Merges by union: existing rules are preserved, duplicates collapse, and no
# other key in the file is touched. Idempotent. Exit 0 = already in sync or
# applied, 3 = differences shown but not applied (no --apply).

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
BLOCK="$HERE/deny-block.json"
TARGET=""; APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --apply)  APPLY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "merge-deny.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$TARGET" ] || { echo "merge-deny.sh: --target <settings.json> is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "merge-deny.sh: jq is required" >&2; exit 2; }
[ -f "$BLOCK" ] || { echo "merge-deny.sh: missing $BLOCK" >&2; exit 2; }

# An absent or empty settings file is treated as {}.
if [ -s "$TARGET" ]; then
  if ! jq -e . "$TARGET" >/dev/null 2>&1; then
    echo "merge-deny.sh: $TARGET is not valid JSON. Fix it first; refusing to overwrite." >&2
    exit 2
  fi
  CURRENT=$(cat "$TARGET")
else
  CURRENT='{}'
fi

WANT=$(jq -r '.permissions.deny[]' "$BLOCK" | sort)
HAVE=$(printf '%s' "$CURRENT" | jq -r '(.permissions.deny // [])[]' | sort)
ADDING=$(comm -23 <(printf '%s\n' "$WANT") <(printf '%s\n' "$HAVE") | grep -v '^$' || true)

echo "target: $TARGET"
if [ ! -f "$TARGET" ]; then echo "        (does not exist yet; would be created)"; fi
echo

if [ -z "$ADDING" ]; then
  echo "Already in sync: all $(printf '%s\n' "$WANT" | grep -c .) recommended deny rules are present."
  echo "Nothing to do."
  exit 0
fi

echo "=== rules that WOULD BE ADDED ($(printf '%s\n' "$ADDING" | grep -c .)) ==="
printf '%s\n' "$ADDING" | sed 's/^/  + /'
echo
KEPT=$(printf '%s\n' "$HAVE" | grep -c . || true)
echo "=== rules already present and kept unchanged: $KEPT ==="
[ "$KEPT" -gt 0 ] && printf '%s\n' "$HAVE" | sed 's/^/    /'
echo
echo "No other key in this file is read or modified."

# The merged document, for review and for writing.
MERGED=$(printf '%s' "$CURRENT" | jq --slurpfile b "$BLOCK" '
  .permissions = ((.permissions // {}) |
    .deny = (((.deny // []) + $b[0].permissions.deny) | unique))')

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "=== resulting permissions.deny ==="
  printf '%s\n' "$MERGED" | jq '.permissions.deny'
  echo
  echo "NOT WRITTEN. Re-run with --apply to write this file."
  exit 3
fi

if [ -f "$TARGET" ]; then
  BACKUP="$TARGET.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$TARGET" "$BACKUP"
  echo "backup: $BACKUP"
fi
mkdir -p "$(dirname "$TARGET")"
TMP="$TARGET.tmp.$$"
printf '%s\n' "$MERGED" > "$TMP"
jq -e . "$TMP" >/dev/null || { rm -f "$TMP"; echo "merge produced invalid JSON; aborted" >&2; exit 2; }
mv "$TMP" "$TARGET"
echo "applied to $TARGET"
exit 0

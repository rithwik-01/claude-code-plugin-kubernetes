#!/usr/bin/env bash
# diff-hygiene.sh -- G4. Asserts the working diff touches nothing it shouldn't.
#
# Usage: diff-hygiene.sh [<base-ref>]      (default: HEAD)
#
# Fails when the diff contains:
#   - go.mod / go.sum / go.work / vendor/ / third_party/  (dependency change)
#   - LICENSES/                                            (implies a new dep)
#   - a generated file edited by hand
#   - a scratch/debug leftover (.orig, .rej, *.log, TODO-XXX markers)
#
# Exit 0 = clean, 1 = dirty. bash 3.2 compatible.

set -u
BASE="${1:-HEAD}"

FILES=$(git diff --name-only "$BASE" 2>/dev/null; git diff --name-only --cached "$BASE" 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
FILES=$(printf '%s\n' "$FILES" | sort -u | grep -v '^$')

echo "=== files in diff vs $BASE ==="
printf '%s\n' "$FILES"
echo
echo "=== diffstat ==="
git diff --stat "$BASE" 2>/dev/null
echo

RC=0
flag() { echo "G4 VIOLATION: $1"; RC=1; }

# --- dependency files ------------------------------------------------------
DEPS=$(printf '%s\n' "$FILES" | grep -E '(^|/)(go\.mod|go\.sum|go\.work|go\.work\.sum)$|(^|/)vendor/|(^|/)third_party/|(^|/)LICENSES/')
if [ -n "$DEPS" ]; then
  flag "the diff changes dependency files. A bug fix must not add or re-resolve modules:"
  printf '  %s\n' $DEPS
fi

# --- hand-edited generated code -------------------------------------------
for f in $FILES; do
  [ -f "$f" ] || continue
  case "$f" in
    *.go)
      if head -5 "$f" 2>/dev/null | grep -q 'Code generated .* DO NOT EDIT'; then
        flag "'$f' is generated (DO NOT EDIT). Re-run the repo's update script instead of editing it."
      fi ;;
  esac
done

# --- scratch leftovers -----------------------------------------------------
JUNK=$(printf '%s\n' "$FILES" | grep -E '\.(orig|rej|swp|bak|log|out|tmp)$|(^|/)__debug|(^|/)\.DS_Store$')
if [ -n "$JUNK" ]; then
  flag "scratch/leftover files are in the diff:"
  printf '  %s\n' $JUNK
fi

# --- debug markers introduced by the change --------------------------------
ADDED=$(git diff -U0 "$BASE" 2>/dev/null | grep -E '^\+' | grep -v '^\+\+\+')
MARKERS=$(printf '%s\n' "$ADDED" | grep -nE 'fmt\.Print|println\(|spew\.Dump|XXX-DEBUG|//[[:space:]]*DEBUG')
if [ -n "$MARKERS" ]; then
  echo "G4 NOTE: possible debug leftovers in added lines (review, not automatically fatal):"
  printf '%s\n' "$MARKERS" | head -20
fi

echo
if [ "$RC" -eq 0 ]; then
  echo "G4: clean"
else
  echo "G4: violations found (see above)"
fi
exit $RC

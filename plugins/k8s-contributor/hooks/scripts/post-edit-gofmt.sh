#!/usr/bin/env bash
# post-edit-gofmt.sh -- PostToolUse(Edit|Write) hook.
#
# Reports gofmt/goimports drift on the file that was just edited. Advisory
# only: PostToolUse cannot block (exit 2 is non-blocking for this event), and
# silently rewriting the model's edit would hide formatting mistakes rather
# than teach them. So this prints the drift and the exact fix command.
#
# exit 0 always. bash 3.2 compatible.

set -u

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -n "$FILE" ] || exit 0
case "$FILE" in *.go) ;; *) exit 0 ;; esac
[ -f "$FILE" ] || exit 0

command -v gofmt >/dev/null 2>&1 || exit 0

DRIFT=$(gofmt -l "$FILE" 2>/dev/null)
if [ -n "$DRIFT" ]; then
  printf 'gofmt drift in %s -- run: gofmt -w %s\n' "$FILE" "$FILE" >&2
fi

# goimports only if the repo already depends on it (never install anything).
REPO_ROOT=$(cd "$(dirname "$FILE")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$REPO_ROOT" ] && command -v goimports >/dev/null 2>&1; then
  if grep -rqs "goimports" "$REPO_ROOT/hack" "$REPO_ROOT/Makefile" "$REPO_ROOT/.golangci.yml" "$REPO_ROOT/.golangci.yaml" 2>/dev/null; then
    IDRIFT=$(goimports -l "$FILE" 2>/dev/null)
    if [ -n "$IDRIFT" ]; then
      printf 'goimports drift in %s -- run: goimports -w %s\n' "$FILE" "$FILE" >&2
    fi
  fi
fi

exit 0

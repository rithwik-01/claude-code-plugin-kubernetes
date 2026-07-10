#!/usr/bin/env bash
# guard-deps.sh -- PreToolUse(Edit|Write|Bash) hook.
#
# Enforces "never invent a dependency": no edits to go.mod / go.sum / vendor/ /
# third_party/, and no command that would rewrite them (go get, go mod tidy,
# go mod vendor, go work sync).
#
# Escape hatch: the block lifts only when
#   <project>/.claude/k8s-contributor/state/<repo>/<issue>/allow-deps
# exists. That file is created ONLY after the user explicitly approves the
# dependency change and the rationale is recorded in plan.md.
#
# exit 2 = block, exit 0 = allow. bash 3.2 compatible.

set -u

# The plugin lives in a cache directory that is replaced on every update, so
# it never resolves paths relative to itself. Run state belongs to the user's
# project; ${CLAUDE_PROJECT_DIR} is exported to hook processes by Claude Code.
. "$(cd "$(dirname "$0")/../../scripts/lib" && pwd -P)/paths.sh"
STATE_DIR="$(k8s_state_root)"

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
CMD=$(printf '%s'  "$INPUT" | jq -r '.tool_input.command // empty')

# An approval token anywhere under .claude/state/ lifts the block for this run.
approved() {
  [ -d "$STATE_DIR" ] || return 1
  find "$STATE_DIR" -name allow-deps -type f 2>/dev/null | grep -q . && return 0
  return 1
}

deny() {
  cat >&2 <<EOF
BLOCKED by guard-deps.sh: $1

Hard rule for this workspace: never invent a dependency. A Kubernetes bug fix
does not add, remove, or re-resolve modules. Use what the package already
imports, or a helper that already exists in the repo.

If the fix genuinely requires a dependency change, that is a finding to report
to the user, not something to do. Say so in plan.md and stop. Only after the
user approves may the escape-hatch file be created at
  $STATE_DIR/<repo>/<issue>/allow-deps
EOF
  exit 2
}

# ------------------------------------------------------------- file targets
if [ -n "$FILE" ]; then
  case "$TOOL" in
    Edit|Write|NotebookEdit|MultiEdit)
      case "$FILE" in
        */go.mod|go.mod)             approved || deny "writing go.mod" ;;
        */go.sum|go.sum)             approved || deny "writing go.sum" ;;
        */go.work|go.work|*/go.work.sum|go.work.sum)
                                     approved || deny "writing $FILE" ;;
        */vendor/*|vendor/*)         approved || deny "writing inside vendor/" ;;
        */third_party/*|third_party/*)
                                     approved || deny "writing inside third_party/" ;;
        */LICENSES/*)                approved || deny "writing inside LICENSES/ (implies a dependency change)" ;;
      esac ;;
  esac
fi

# --------------------------------------------------------- command targets
if [ -n "$CMD" ]; then
  # Same normalization idea as guard-destructive.sh: unwrap quoting/nesting so
  # `bash -c "go mod tidy"` is caught too.
  NORM=$(printf '%s' "$CMD" \
    | tr '\n\r\t' '   ' \
    | sed -e 's/\\//g' -e "s/[\"']/ /g" -e 's/\$(/ /g' \
          -e 's/[\`(){}]/ /g' -e 's/&&/ /g' -e 's/||/ /g' -e 's/[;|&]/ /g' \
    | tr -s ' ')

  if printf '%s' "$NORM" | grep -Eq '(^| )go +get( |$)'; then
    approved || deny "'go get' resolves and writes go.mod/go.sum"
  fi
  if printf '%s' "$NORM" | grep -Eq '(^| )go +mod +(tidy|vendor|edit|download)( |$)'; then
    approved || deny "'go mod tidy/vendor/edit/download' rewrites go.mod, go.sum, or vendor/"
  fi
  if printf '%s' "$NORM" | grep -Eq '(^| )go +work +(sync|edit|use)( |$)'; then
    approved || deny "'go work' rewrites go.work"
  fi
  # gwctl's Makefile: `make build`, `make test` and `make verify` all depend on
  # a `deps` target that runs `go mod tidy && go mod vendor`. Running them
  # dirties the dependency files, so they need the same gate.
  if printf '%s' "$NORM" | grep -Eq '(^| )make +deps( |$)'; then
    approved || deny "'make deps' runs 'go mod tidy && go mod vendor' in this repo"
  fi
fi

exit 0

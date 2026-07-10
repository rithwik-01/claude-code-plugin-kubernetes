#!/usr/bin/env bash
# guard-scope.sh -- PreToolUse(Edit|Write) hook.
#
# Confines every write to the workspace: a sibling repo clone under the
# workspace root, or the run's own state directory. Anything else -- $HOME
# dotfiles, /etc, a path that traverses out with ../ -- is blocked.
#
# The check is done on the RESOLVED path, so `kubernetes/../../escape.txt`
# cannot slip past a prefix comparison.
#
# exit 2 = block, exit 0 = allow. bash 3.2 compatible.

set -u

# Never resolve relative to the plugin root -- it is a cache dir replaced on
# every update, and it is not where the user's code lives.
. "$(cd "$(dirname "$0")/../../scripts/lib" && pwd -P)/paths.sh"
PROJECT_DIR="$(k8s_project_dir)"

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // empty')
# Plugin-shipped agents are reported scoped: "k8s-contributor:reviewer-tests".
# Strip any "<plugin>:" prefix so the confinement patterns below keep matching
# whether the agent came from this plugin or from a local .claude/agents/ copy.
AGENT="${AGENT##*:}"
[ -n "$FILE" ] || exit 0

# Resolve without requiring the file to exist yet: realpath the deepest
# existing ancestor, then re-append the remainder.
resolve() {
  p="$1"
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  head="$p"; tail=""
  while [ ! -e "$head" ] && [ "$head" != "/" ] && [ -n "$head" ]; do
    tail="$(basename "$head")${tail:+/$tail}"
    head="$(dirname "$head")"
  done
  if [ -d "$head" ]; then
    head="$(cd "$head" 2>/dev/null && pwd -P)" || head="$1"
  fi
  printf '%s' "${head%/}${tail:+/$tail}"
}

ABS=$(resolve "$FILE")
ROOT="$PROJECT_DIR"

deny() {
  cat >&2 <<EOF
BLOCKED by guard-scope.sh: $1

  requested: $FILE
  resolved : $ABS
  workspace: $ROOT

Writes are confined to the workspace: a repo clone under the workspace root,
or this run's state directory
(.claude/k8s-contributor/state/<repo>/<issue>/). Nothing outside
it may be modified -- not \$HOME, not /etc, not a sibling of the workspace.
If you need a scratch file, put it in the run's state directory.
EOF
  exit 2
}

# Must live under the workspace root.
case "$ABS/" in
  "$ROOT"/*) ;;
  *) deny "target is outside the workspace root" ;;
esac

# ------------------------------------------------- read-only agent confinement
# Reviewers and triage investigators must never modify the code they judge.
# Their frontmatter already denies Write/Edit, but enabling `memory:` re-adds
# those tools so the agent can curate its own notes. This check keeps that
# escape hatch pointed at the memory directory only -- a hook cannot be talked
# out of it the way frontmatter can.
case "$AGENT" in
  reviewer-*|issue-analyst|duplicate-hunter|code-locator|behavior-adjudicator|plan-reviewer|synthesizer)
      case "$ABS" in
        "$ROOT"/.claude/k8s-contributor/*) exit 0 ;;
        *) deny "agent '$AGENT' is read-only; it may write only under .claude/k8s-contributor/" ;;
      esac ;;
  reproducer|verifier)
      # These two run commands and capture evidence, so they may write, but
      # only inside a run's state directory -- never into a repo clone.
      case "$ABS" in
        "$ROOT"/.claude/k8s-contributor/*) exit 0 ;;
        *) deny "agent '$AGENT' may write only inside .claude/k8s-contributor/state/<repo>/<issue>/" ;;
      esac ;;
esac

# Under the root, allow: any first-level directory (the repo clones), and this
# plugin's own subtree .claude/k8s-contributor/ (run state). The rest of
# .claude/ stays writable because /k8s-setup merges the recommended
# permissions.deny block into .claude/settings.json -- that write is gated on
# the user's explicit confirmation in the skill, not here.
REL="${ABS#$ROOT/}"
case "$REL" in
  .claude/k8s-contributor/*)
      exit 0 ;;
  .claude/*)
      # Allow during the build/maintenance of the system itself, but say so.
      exit 0 ;;
  */*)
      # <repo-clone>/<path> -- confirm the first segment is a real directory.
      TOP="${REL%%/*}"
      [ -d "$ROOT/$TOP" ] || deny "'$TOP' is not an existing directory in the workspace"
      exit 0 ;;
  *)
      # A bare file at the workspace root (CLAUDE.md, task.md).
      exit 0 ;;
esac

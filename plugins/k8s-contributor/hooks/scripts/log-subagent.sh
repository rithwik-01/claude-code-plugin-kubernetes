#!/usr/bin/env bash
# log-subagent.sh -- SubagentStop hook.
#
# Appends a one-line record per finished subagent to the active run's
# append-only log, so a resumed session can see which agents already ran.
#
# The active run is whichever
# .claude/k8s-contributor/state/<repo>/<issue>/ directory was touched most
# recently (the skills write run.md at intake, which stamps it).
#
# exit 0 always -- SubagentStop exit 2 would block the agent's result.

set -u

. "$(cd "$(dirname "$0")/../../scripts/lib" && pwd -P)/paths.sh"
STATE_DIR="$(k8s_state_root)"
[ -d "$STATE_DIR" ] || exit 0

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // "unknown"')
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // "-"')
LAST=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""')

# Most recently modified run.md wins; that is the run currently in progress.
RUN_MD=$(find "$STATE_DIR" -name run.md -type f 2>/dev/null \
         | while read -r f; do printf '%s %s\n' "$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null)" "$f"; done \
         | sort -rn | head -1 | cut -d' ' -f2-)
[ -n "$RUN_MD" ] || exit 0

# Pull the verdict out of the agent's JSON result if it returned the contract.
VERDICT=$(printf '%s' "$LAST" | sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([a-z-]*\)".*/\1/p' | head -1)
[ -n "$VERDICT" ] || VERDICT="-"

printf -- '- %s  subagent=%-24s verdict=%-12s id=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$AGENT" "$VERDICT" "$AGENT_ID" >> "$RUN_MD"

exit 0

#!/usr/bin/env bash
# paths.sh -- the one place that decides where anything is written.
#
# Source it; do not execute it.
#
# A plugin is copied into a cache directory that is REPLACED on every update,
# so ${CLAUDE_PLUGIN_ROOT} is read-only as far as this system is concerned.
# Everything written falls into exactly one of two buckets:
#
#   RUN STATE   -- evidence, logs, gate.json, drafts. Belongs next to the code
#                  being fixed, under the user's own repo/workspace, so it can
#                  be inspected and gitignored:
#                     <project>/.claude/k8s-contributor/state/<repo>/<issue>/
#
#   CROSS-RUN   -- detected repo profiles, fetched community docs, agent memory
#     CACHE        seeds. Survives plugin updates:
#                     ${CLAUDE_PLUGIN_DATA}/
#
# Resolution order for each, most explicit first:
#   1. an explicit --state-root / --data flag parsed by the calling script
#   2. K8S_STATE_ROOT / K8S_DATA_ROOT in the environment
#   3. CLAUDE_PROJECT_DIR / CLAUDE_PLUGIN_DATA exported by Claude Code
#   4. a documented fallback ($PWD, $HOME/.claude/k8s-contributor)
#
# CLAUDE_PLUGIN_DATA is substituted into skill markdown and hook commands, but
# it is NOT guaranteed in the environment of a plain Bash tool call, which is
# why every script also accepts --data. bash 3.2 compatible.

# k8s_project_dir -- the user's workspace root (holds the repo clones).
k8s_project_dir() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    (cd "$CLAUDE_PROJECT_DIR" && pwd -P)
  else
    pwd -P
  fi
}

# k8s_state_root [override] -- run state lives under the user's project.
k8s_state_root() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return; fi
  if [ -n "${K8S_STATE_ROOT:-}" ]; then printf '%s' "$K8S_STATE_ROOT"; return; fi
  printf '%s/.claude/k8s-contributor/state' "$(k8s_project_dir)"
}

# k8s_data_root [override] -- cross-run cache, survives plugin updates.
k8s_data_root() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return; fi
  if [ -n "${K8S_DATA_ROOT:-}" ]; then printf '%s' "$K8S_DATA_ROOT"; return; fi
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then printf '%s' "$CLAUDE_PLUGIN_DATA"; return; fi
  printf '%s/.claude/k8s-contributor' "${HOME:-/tmp}"
}

k8s_profiles_dir()  { printf '%s/profiles' "$(k8s_data_root "${1:-}")"; }
k8s_community_dir() { printf '%s/community-docs' "$(k8s_data_root "${1:-}")"; }
k8s_memory_dir()    { printf '%s/agent-memory' "$(k8s_data_root "${1:-}")"; }

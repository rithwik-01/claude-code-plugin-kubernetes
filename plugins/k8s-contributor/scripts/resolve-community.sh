#!/usr/bin/env bash
# resolve-community.sh -- find the kubernetes/community contributor docs.
#
# The guidelines skill must cite a real file on disk. On the author's machine
# that was a sibling clone; on everyone else's machine it is somewhere else or
# nowhere. Resolution order, most authoritative first:
#
#   1. --path / CLAUDE_PLUGIN_OPTION_COMMUNITY_DOCS_PATH  (userConfig)
#   2. auto-detect: a community/ dir beside the workspace or the current repo,
#      or $GOPATH/src/k8s.io/community
#   3. the cached copy under <plugin-data>/community-docs/, refetching when it
#      is older than --max-age-days (default 30)
#   4. fetch from https://github.com/kubernetes/community into that cache
#   5. fail loudly -- never let the caller proceed on guessed conventions
#
# Prints the resolved contributors/ directory on stdout, and a one-line
# provenance note on stderr. Exit 0 = resolved, 4 = unresolved.
#
# Deliberately `set -u` only: probing for absent directories is the normal
# path, and `-e` would abort on the first miss. bash 3.2 compatible.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/lib/paths.sh"

PATH_OVERRIDE=""; DATA_OVERRIDE=""; MAX_AGE_DAYS=30; DO_FETCH=1; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --path)          PATH_OVERRIDE="${2:-}"; shift 2 ;;
    --data)          DATA_OVERRIDE="${2:-}"; shift 2 ;;
    --max-age-days)  MAX_AGE_DAYS="${2:-30}"; shift 2 ;;
    --no-fetch)      DO_FETCH=0; shift ;;
    --quiet)         QUIET=1; shift ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "resolve-community.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

note() { [ "$QUIET" -eq 1 ] || printf 'community-docs: %s\n' "$1" >&2; }

# A directory qualifies only if it actually holds the guide we cite.
valid() { [ -n "${1:-}" ] && [ -d "$1/contributors/guide" ]; }
emit()  { printf '%s\n' "$1/contributors"; }

# ---------------------------------------------------------- 1. explicit config
CONFIGURED="$PATH_OVERRIDE"
[ -n "$CONFIGURED" ] || CONFIGURED="${CLAUDE_PLUGIN_OPTION_COMMUNITY_DOCS_PATH:-}"
if [ -n "$CONFIGURED" ]; then
  if valid "$CONFIGURED"; then
    note "using configured clone at $CONFIGURED"
    emit "$CONFIGURED"; exit 0
  fi
  note "WARNING: community_docs_path is set to '$CONFIGURED' but that is not a
              kubernetes/community clone (no contributors/guide/). Ignoring it."
fi

# ------------------------------------------------------------ 2. auto-detect
PROJECT="$(k8s_project_dir)"
for cand in \
  "$PROJECT/community" \
  "$PROJECT/../community" \
  "$(pwd -P)/community" \
  "$(pwd -P)/../community" \
  "${GOPATH:-$HOME/go}/src/k8s.io/community"
do
  if valid "$cand"; then
    RESOLVED=$(cd "$cand" && pwd -P)
    note "auto-detected clone at $RESOLVED"
    emit "$RESOLVED"; exit 0
  fi
done

# ------------------------------------------- 3/4. cached copy, fetch if stale
CACHE="$(k8s_community_dir "$DATA_OVERRIDE")"
STAMP="$CACHE/.fetched-at"

cache_age_days() {
  [ -f "$STAMP" ] || { echo 99999; return; }
  then_=$(cat "$STAMP" 2>/dev/null)
  case "$then_" in ''|*[!0-9]*) echo 99999; return ;; esac
  now=$(date -u +%s)
  echo $(( (now - then_) / 86400 ))
}

AGE=$(cache_age_days)
if valid "$CACHE" && [ "$AGE" -le "$MAX_AGE_DAYS" ]; then
  note "using cached docs at $CACHE (fetched ${AGE}d ago)"
  emit "$CACHE"; exit 0
fi

if [ "$DO_FETCH" -eq 1 ]; then
  if command -v git >/dev/null 2>&1; then
    note "fetching kubernetes/community (cache is ${AGE}d old, max ${MAX_AGE_DAYS}d)"
    TMP="$CACHE.tmp.$$"
    rm -rf "$TMP"
    mkdir -p "$(dirname "$CACHE")"
    # Only the contributor docs are needed; a blobless partial clone of one
    # directory keeps this to a few MB instead of the full ~500MB history.
    if git clone --depth 1 --filter=blob:none --sparse \
         https://github.com/kubernetes/community.git "$TMP" >/dev/null 2>&1 &&
       (cd "$TMP" && git sparse-checkout set contributors >/dev/null 2>&1)
    then
      if valid "$TMP"; then
        rm -rf "$CACHE"
        mv "$TMP" "$CACHE"
        date -u +%s > "$STAMP"
        note "cached to $CACHE"
        emit "$CACHE"; exit 0
      fi
    fi
    rm -rf "$TMP"
    note "fetch failed (offline, or GitHub unreachable)"
  else
    note "git is not installed, cannot fetch"
  fi
fi

# A stale cache still beats nothing, as long as the staleness is stated.
if valid "$CACHE"; then
  note "WARNING: using STALE cached docs at $CACHE (${AGE}d old, refetch failed).
              Verify anything you cite against https://github.com/kubernetes/community"
  emit "$CACHE"; exit 0
fi

# ----------------------------------------------------------- 5. degrade loudly
cat >&2 <<EOF
community-docs: UNRESOLVED.

The kubernetes/community contributor guidelines could not be found, and they
could not be fetched. Do NOT proceed on remembered conventions: triage
verdicts, Prow commands, PR templates, and cherry-pick rules all change, and a
confidently-wrong citation is worse than an admitted gap.

Fix it with any one of:
  1. Clone the docs and point the plugin at them:
       git clone --depth 1 https://github.com/kubernetes/community
       /plugin config k8s-contributor            # set community_docs_path
  2. Place a community/ clone beside your other repo clones.
  3. Restore network access and re-run /k8s-setup.

Until then, state in your output that guidelines could not be verified, and
cite the upstream URL rather than a section you cannot read.
EOF
exit 4

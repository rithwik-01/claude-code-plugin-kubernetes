#!/usr/bin/env bash
# check-prereqs.sh -- report which tools /k8s-fix and /k8s-verify need, which
# are present, and the exact command to install each missing one.
#
# INSTALLS NOTHING. It prints; the user decides. bash 3.2 compatible.
#
# Exit: 0 if every REQUIRED tool is present, 1 otherwise (optional tools
# missing never fail the check -- they only narrow which gates can run).

set -u

REPO_DIR="${1:-}"
MISSING_REQUIRED=0

row() { printf '  %-9s %-9s %s\n' "$1" "$2" "$3"; }

check() {  # check <name> <required|optional> <install-hint> <what-it-unblocks>
  name="$1"; req="$2"; hint="$3"; unblocks="$4"
  if command -v "$name" >/dev/null 2>&1; then
    # `go` and `etcd` do not accept --version; ask each the way it expects.
    case "$name" in
      go)    ver=$(go version 2>/dev/null | head -1) ;;
      etcd)  ver=$(etcd --version 2>/dev/null | head -1) ;;
      *)     ver=$("$name" --version 2>/dev/null | head -1) ;;
    esac
    row "$name" "present" "$(printf '%s' "${ver:-ok}" | cut -c1-40)"
  else
    row "$name" "MISSING" "$hint  ($unblocks)"
    [ "$req" = "required" ] && MISSING_REQUIRED=1
  fi
}

echo "=== prerequisites ==="
printf '  %-9s %-9s %s\n' "tool" "status" "detail"
check gh     required "brew install gh"            "issue fetch, duplicate search"
check go     required "https://go.dev/dl/"         "every build and test gate"
check git    required "xcode-select --install"     "diffs, branches, doc fetch"
check jq     required "brew install jq"            "gate.json, hook payload parsing"
check docker optional "https://docker.com/get-started" "G6 cluster gate"
check kind   optional "brew install kind"          "G6 cluster gate"
check etcd   optional "hack/install-etcd.sh in the k8s repo" "G5 integration gate"

# --- gh auth is separate from gh being installed --------------------------
echo
echo "=== gh authentication ==="
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    who=$(gh auth status 2>&1 | sed -n 's/.*account \([^ ]*\).*/\1/p' | head -1)
    echo "  authenticated as ${who:-(unknown)}"
  else
    echo "  NOT AUTHENTICATED -- run: gh auth login"
    MISSING_REQUIRED=1
  fi
else
  echo "  gh not installed (see above)"
fi

# --- Go version vs what the repo asks for ---------------------------------
if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ]; then
  echo
  echo "=== go version vs $(basename "$REPO_DIR") ==="
  want=""
  [ -f "$REPO_DIR/.go-version" ] && want=$(head -1 "$REPO_DIR/.go-version" 2>/dev/null)
  if [ -z "$want" ] && [ -f "$REPO_DIR/go.mod" ]; then
    want=$(sed -n 's/^go \([0-9.]*\).*/\1/p' "$REPO_DIR/go.mod" 2>/dev/null | head -1)
  fi
  have=$(go version 2>/dev/null | sed -n 's/.*go\([0-9][0-9.]*\).*/\1/p')
  if [ -n "$want" ] && [ -n "$have" ]; then
    echo "  repo wants go $want, you have go $have"
    # Compare on major.minor only. A newer patch release (1.26.4 vs 1.26.0) is
    # normal and not a mismatch; a different minor is what actually bites.
    wmm=$(printf '%s' "$want" | cut -d. -f1,2)
    hmm=$(printf '%s' "$have" | cut -d. -f1,2)
    if [ "$wmm" = "$hmm" ]; then
      echo "  -> match (go $hmm)"
    else
      echo "  -> MISMATCH on the minor version ($hmm vs $wmm)."
      echo "     Builds may fail or silently differ from CI."
    fi
  else
    echo "  could not determine (want='${want:-?}' have='${have:-?}')"
  fi
fi

echo
if [ "$MISSING_REQUIRED" -eq 0 ]; then
  echo "All required tools present."
else
  echo "Some REQUIRED tooling is missing or unauthenticated (see above)."
  echo "Nothing was installed. Install what you want, then re-run /k8s-setup."
fi
exit "$MISSING_REQUIRED"

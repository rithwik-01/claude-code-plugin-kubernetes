#!/usr/bin/env bash
# kind-down.sh -- paired teardown for kind-up.sh.
#
# Always exports cluster logs into the run's evidence/ directory BEFORE
# deleting, so a failed G6 leaves the diagnostic behind.
#
# Usage: kind-down.sh --name fix-<issue> [--state <dir>] [--no-logs]

set -u

NAME=""; STATE=""; LOGS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --name)  NAME="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --no-logs) LOGS=0; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "kind-down.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$NAME" ] || { echo "kind-down.sh: --name is required" >&2; exit 2; }
command -v kind >/dev/null 2>&1 || { echo "kind-down.sh: kind is not installed" >&2; exit 0; }

if ! kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  echo "kind-down: no cluster named '$NAME'; nothing to do."
  exit 0
fi

if [ "$LOGS" -eq 1 ] && [ -n "$STATE" ]; then
  DEST="$STATE/evidence/kind-logs-$NAME"
  mkdir -p "$DEST"
  echo "kind-down: exporting cluster logs to $DEST"
  kind export logs "$DEST" --name "$NAME" >/dev/null 2>&1 \
    || echo "kind-down: log export failed (continuing to delete)"
fi

echo "kind-down: deleting cluster '$NAME'"
kind delete cluster --name "$NAME"

# The built node image is large; leave it but say so, since rebuilding costs
# many minutes and the user may want another run.
if docker image inspect "kindest/node:$NAME" >/dev/null 2>&1; then
  echo
  echo "The node image kindest/node:$NAME is still on disk (rebuilding is slow)."
  echo "Remove it yourself when done:  docker rmi kindest/node:$NAME"
fi
exit 0

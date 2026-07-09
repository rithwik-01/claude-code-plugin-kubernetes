#!/usr/bin/env bash
# kind-up.sh -- G6. Bring up a kind cluster that actually contains your change.
#
# THE CRITICAL SUBTLETY: `kind create cluster` alone boots a RELEASED node
# image and will not contain your fix. Verifying a kubelet / apiserver /
# scheduler / controller-manager change requires building the node image from
# the working tree first. This script does that by default.
#
# Usage:
#   kind-up.sh --repo <k8s-src-dir> --name fix-<issue> [--state <dir>]
#              [--config <kind-config.yaml>] [--no-build] [--keep]
#
#   --no-build   use the stock released node image. ONLY valid when the change
#                under test is not in the cluster binaries (e.g. a CLI tool
#                like gwctl driven against a plain cluster).
#   --keep       do not delete the cluster on exit (default is to clean up).
#
# On failure the script exports cluster logs into <state>/evidence/ before
# tearing down, so a failed G6 still leaves evidence behind.
#
# bash 3.2 compatible.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"

REPO=""; NAME=""; STATE=""; CONFIG=""; BUILD=1; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="$2"; shift 2 ;;
    --name)   NAME="$2"; shift 2 ;;
    --state)  STATE="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --keep)   KEEP=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "kind-up.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$NAME" ] || { echo "kind-up.sh: --name is required (use fix-<issue>)" >&2; exit 2; }

command -v kind    >/dev/null 2>&1 || { echo "kind-up.sh: kind is not installed" >&2; exit 2; }
command -v kubectl >/dev/null 2>&1 || { echo "kind-up.sh: kubectl is not installed" >&2; exit 2; }
if ! docker info >/dev/null 2>&1 && ! podman info >/dev/null 2>&1; then
  echo "kind-up.sh: no running container runtime (docker/podman). Start one first." >&2
  exit 2
fi

EVIDENCE="${STATE:+$STATE/evidence}"
[ -n "$EVIDENCE" ] && mkdir -p "$EVIDENCE"
log() { echo "kind-up: $*"; }

IMAGE="kindest/node:latest"

# ---------------------------------------------------- build node image from src
if [ "$BUILD" -eq 1 ]; then
  [ -n "$REPO" ] || { echo "kind-up.sh: --repo <kubernetes source dir> is required unless --no-build" >&2; exit 2; }
  [ -d "$REPO" ] || { echo "kind-up.sh: no such repo dir: $REPO" >&2; exit 2; }
  REPO=$(cd "$REPO" && pwd -P)
  if [ ! -f "$REPO/Makefile" ] || [ ! -d "$REPO/cmd/kubelet" ]; then
    echo "kind-up.sh: $REPO does not look like a kubernetes/kubernetes checkout." >&2
    echo "  For a CLI tool verified against a stock cluster, pass --no-build." >&2
    exit 2
  fi
  IMAGE="kindest/node:$NAME"
  log "building a node image from source -- this compiles Kubernetes and takes a while"
  log "  source: $REPO"
  log "  image:  $IMAGE"
  BUILD_LOG="${EVIDENCE:-/tmp}/G6-kind-build.log"
  if ! ( cd "$REPO" && kind build node-image --image "$IMAGE" ) 2>&1 | tee "$BUILD_LOG"; then
    echo "kind-up.sh: node image build FAILED; see $BUILD_LOG" >&2
    exit 1
  fi
  log "node image built: $IMAGE"
else
  log "--no-build: using the stock released node image."
  log "  NOTE: a change to kubelet/apiserver/scheduler/controller-manager will NOT"
  log "  be present in this cluster. Only use --no-build to drive an external binary."
fi

# ------------------------------------------------------------- create cluster
CREATE="kind create cluster --name $NAME --image $IMAGE"
[ -n "$CONFIG" ] && CREATE="$CREATE --config $CONFIG"

log "creating cluster: $CREATE"
CREATE_LOG="${EVIDENCE:-/tmp}/G6-kind-create.log"
if ! $CREATE 2>&1 | tee "$CREATE_LOG"; then
  echo "kind-up.sh: cluster creation FAILED; see $CREATE_LOG" >&2
  if [ -n "$EVIDENCE" ]; then
    kind export logs "$EVIDENCE/kind-logs-failed" --name "$NAME" >/dev/null 2>&1
    log "exported cluster logs to $EVIDENCE/kind-logs-failed"
  fi
  kind delete cluster --name "$NAME" >/dev/null 2>&1
  exit 1
fi

CTX="kind-$NAME"
kubectl cluster-info --context "$CTX" 2>&1 | tee -a "$CREATE_LOG"

# Confirm the nodes really came up before declaring success.
if ! kubectl --context "$CTX" wait --for=condition=Ready nodes --all --timeout=300s; then
  echo "kind-up.sh: nodes did not become Ready" >&2
  [ -n "$EVIDENCE" ] && kind export logs "$EVIDENCE/kind-logs-notready" --name "$NAME" >/dev/null 2>&1
  exit 1
fi

echo
log "cluster is up."
log "  context:  $CTX"
log "  image:    $IMAGE"
[ "$BUILD" -eq 1 ] && log "  contains your working-tree build: YES"
[ "$BUILD" -eq 0 ] && log "  contains your working-tree build: NO (stock image)"
echo
echo "Next: replay the reporter's exact steps against --context $CTX, or run the"
echo "focused e2e suite. Capture output into the run's evidence/ directory."
echo
echo "Tear down when finished:"
echo "  $HERE/kind-down.sh --name $NAME${STATE:+ --state $STATE}"

if [ "$KEEP" -eq 0 ]; then
  echo
  echo "(kind-up.sh does not auto-delete: the cluster is needed after this script"
  echo " exits. kind-down.sh is the paired teardown and exports logs first.)"
fi
exit 0

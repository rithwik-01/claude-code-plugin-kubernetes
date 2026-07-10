#!/usr/bin/env bash
# test-hooks.sh -- self-test for every guard hook.
#
# Feeds each hook a crafted PreToolUse/PostToolUse JSON payload on stdin and
# asserts the exit code: 2 = blocked, 0 = allowed.
#
# Run:  <plugin-root>/hooks/scripts/test-hooks.sh
# Exit: 0 if every case behaves as specified, 1 otherwise.
#
# These are the guardrails the plugin's approval guarantee rests on, so this
# suite runs in CI. It builds a THROWAWAY workspace in a temp dir and points
# CLAUDE_PROJECT_DIR at it, so the results do not depend on the machine it runs
# on and no real repo is touched.

set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"

# A disposable stand-in for the user's workspace.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/k8s-contributor-hooktest.XXXXXX")"
mkdir -p "$ROOT/kubernetes/pkg/kubelet" \
         "$ROOT/kubernetes/vendor/x" \
         "$ROOT/kubernetes/third_party/f" \
         "$ROOT/gwctl/pkg/cmd" \
         "$ROOT/.claude/k8s-contributor/state/kubernetes/1/evidence" \
         "$ROOT/.claude/k8s-contributor/agent-memory/reviewer-correctness"
export CLAUDE_PROJECT_DIR="$ROOT"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

# jq -n builds the payload so quoting inside the command survives intact.
bash_payload() { jq -nc --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:"'"$ROOT"'",tool_input:{command:$c}}'; }
edit_payload() { jq -nc --arg p "$1" '{hook_event_name:"PreToolUse",tool_name:"Edit",cwd:"'"$ROOT"'",tool_input:{file_path:$p}}'; }

# expect <want-exit> <hook> <payload> <label>
expect() {
  want="$1"; hook="$2"; payload="$3"; label="$4"
  out=$(printf '%s' "$payload" | "$HOOKS/$hook" 2>&1)
  got=$?
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS+1))
    printf '  ok    [exit %s] %s\n' "$got" "$label"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL  [exit %s, want %s] %s\n' "$got" "$want" "$label"
    printf '        %s\n' "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  fi
}

blocked_bash() { expect 2 guard-destructive.sh "$(bash_payload "$1")" "BLOCK  $1"; }
allowed_bash() { expect 0 guard-destructive.sh "$(bash_payload "$1")" "ALLOW  $1"; }

echo "=== guard-destructive.sh : must BLOCK (exit 2) ==="
# The exact bad cases named in the build spec, section 9.4:
blocked_bash 'git commit -m "fix"'
blocked_bash 'bash -c "make test && git commit -am wip"'
blocked_bash 'echo $(git push origin HEAD)'
blocked_bash 'gh issue comment 123 --body "/triage accepted"'
blocked_bash 'gh pr create --fill'
blocked_bash 'gh api -X POST /repos/kubernetes/kubernetes/issues/1/comments'
blocked_bash 'echo "/close" | gh issue comment 123 -F -'
# Additional evasion routes this hook is responsible for:
blocked_bash 'git push --force origin master'
blocked_bash 'git tag -a v1.0 -m rel'
blocked_bash 'git rebase -i HEAD~3'
blocked_bash 'git reset --hard HEAD~1'
blocked_bash 'git commit --amend --no-edit'
blocked_bash 'gh pr merge 42 --squash'
blocked_bash 'gh pr review 42 --approve'
blocked_bash 'gh issue close 123'
blocked_bash 'gh issue edit 123 --add-label kind/bug'
blocked_bash 'git -C ../other-checkout commit -am x'
blocked_bash 'GIT_DIR=/tmp/x.git git commit -m y'
blocked_bash 'eval "$PUBLISH_CMD"'
blocked_bash 'echo hi > .git/COMMIT_EDITMSG'
blocked_bash 'printf "/lgtm" | xargs -I{} gh pr comment 1 --body {}'
blocked_bash 'git ci-alias; git push'
blocked_bash 'make verify && gh pr create -t x -b y'

echo
echo "=== guard-destructive.sh : must ALLOW (exit 0) ==="
# The exact good cases named in the build spec, section 9.4:
allowed_bash 'git status'
allowed_bash 'git diff'
allowed_bash 'git stash push -- pkg/foo/bar.go'
allowed_bash 'go test ./...'
allowed_bash 'gh issue view 123'
# Additional day-to-day verification traffic that must never be interrupted:
allowed_bash 'git stash pop'
allowed_bash 'git diff --stat master...HEAD'
allowed_bash 'git log --oneline -20'
allowed_bash 'git worktree add /tmp/wt HEAD'
allowed_bash 'git checkout -b fix/123-slug'
allowed_bash 'gh issue view 12345 --repo kubernetes/kubernetes --json labels'
allowed_bash 'gh search issues "flaky test" --repo kubernetes/kubernetes'
allowed_bash 'gh pr list --search 12345'
allowed_bash 'gh api repos/kubernetes/kubernetes/contents/OWNERS'
allowed_bash 'make test WHAT=./pkg/kubelet KUBE_RACE=-race'
allowed_bash 'go test ./test/integration/scheduler/ -run TestX -race -count=1'
allowed_bash 'hack/install-etcd.sh'
allowed_bash 'kind create cluster --name fix-123'

echo
echo "=== guard-deps.sh ==="
expect 2 guard-deps.sh "$(edit_payload "$ROOT/kubernetes/go.mod")"            "BLOCK  edit go.mod"
expect 2 guard-deps.sh "$(edit_payload "$ROOT/kubernetes/go.sum")"            "BLOCK  edit go.sum"
expect 2 guard-deps.sh "$(edit_payload "$ROOT/kubernetes/vendor/x/y.go")"     "BLOCK  edit vendor/"
expect 2 guard-deps.sh "$(edit_payload "$ROOT/kubernetes/third_party/f/a.go")" "BLOCK  edit third_party/"
expect 0 guard-deps.sh "$(edit_payload "$ROOT/kubernetes/pkg/kubelet/kubelet.go")" "ALLOW  edit pkg/ source"
expect 0 guard-deps.sh "$(edit_payload "$ROOT/.claude/k8s-contributor/state/kubernetes/1/notes.md")" "ALLOW  edit state dir"
expect 2 guard-deps.sh "$(bash_payload 'go get example.com/pkg@latest')"      "BLOCK  go get"
expect 2 guard-deps.sh "$(bash_payload 'go mod tidy')"                        "BLOCK  go mod tidy"
expect 0 guard-deps.sh "$(bash_payload 'go build ./...')"                     "ALLOW  go build"

echo
echo "=== guard-scope.sh ==="
expect 0 guard-scope.sh "$(edit_payload "$ROOT/kubernetes/pkg/kubelet/kubelet.go")" "ALLOW  inside a sibling repo clone"
expect 0 guard-scope.sh "$(edit_payload "$ROOT/.claude/k8s-contributor/state/kubernetes/1/run.md")" "ALLOW  inside the run state dir"
expect 0 guard-scope.sh "$(edit_payload "$ROOT/gwctl/pkg/cmd/get.go")"              "ALLOW  inside gwctl clone"
expect 2 guard-scope.sh "$(edit_payload "/etc/hosts")"                              "BLOCK  outside the workspace"
expect 2 guard-scope.sh "$(edit_payload "$HOME/.zshrc")"                            "BLOCK  home dotfile"
expect 2 guard-scope.sh "$(edit_payload "$ROOT/../escape.txt")"                     "BLOCK  parent of workspace root"
expect 2 guard-scope.sh "$(edit_payload "$ROOT/kubernetes/../../escape.txt")"       "BLOCK  traversal out of a clone"

echo
echo "=== guard-scope.sh : read-only agent confinement (agent_type aware) ==="
agent_payload() { jq -nc --arg p "$1" --arg a "$2" '{hook_event_name:"PreToolUse",tool_name:"Edit",agent_type:$a,cwd:"'"$ROOT"'",tool_input:{file_path:$p}}'; }
expect 2 guard-scope.sh "$(agent_payload "$ROOT/kubernetes/pkg/kubelet/kubelet.go" reviewer-correctness)" "BLOCK  reviewer editing repo source"
expect 0 guard-scope.sh "$(agent_payload "$ROOT/.claude/k8s-contributor/agent-memory/reviewer-correctness/MEMORY.md" reviewer-correctness)" "ALLOW  reviewer writing its own memory"
expect 2 guard-scope.sh "$(agent_payload "$ROOT/kubernetes/pkg/x.go" code-locator)"        "BLOCK  code-locator editing repo source"
expect 2 guard-scope.sh "$(agent_payload "$ROOT/kubernetes/pkg/x.go" reproducer)"          "BLOCK  reproducer editing repo source"
expect 0 guard-scope.sh "$(agent_payload "$ROOT/.claude/k8s-contributor/state/kubernetes/1/evidence/r.log" reproducer)" "ALLOW  reproducer writing evidence"
expect 0 guard-scope.sh "$(agent_payload "$ROOT/kubernetes/pkg/x.go" "")"                  "ALLOW  main thread (worker) editing repo source"

echo
echo "=== guard-scope.sh : plugin-scoped agent names must confine identically ==="
# Plugin agents are reported as "k8s-contributor:<name>"; the hook strips that
# prefix, so these must behave exactly like the unscoped cases above.
expect 2 guard-scope.sh "$(agent_payload "$ROOT/kubernetes/pkg/kubelet/kubelet.go" k8s-contributor:reviewer-correctness)" "BLOCK  scoped reviewer editing repo source"
expect 0 guard-scope.sh "$(agent_payload "$ROOT/.claude/k8s-contributor/agent-memory/reviewer-correctness/MEMORY.md" k8s-contributor:reviewer-correctness)" "ALLOW  scoped reviewer writing its own memory"
expect 2 guard-scope.sh "$(agent_payload "$ROOT/kubernetes/pkg/x.go" k8s-contributor:reproducer)" "BLOCK  scoped reproducer editing repo source"

echo
echo "=== guard-destructive.sh : the userConfig option is NOT a bypass ==="
# require_approval_before_commit=false is documented as unsupported. The hook
# must still block, and the refusal must say so.
BYPASS_OUT=$(printf '%s' "$(bash_payload 'git commit -m x')" \
  | CLAUDE_PLUGIN_OPTION_REQUIRE_APPROVAL_BEFORE_COMMIT=false "$HOOKS/guard-destructive.sh" 2>&1)
BYPASS_RC=$?
if [ "$BYPASS_RC" -eq 2 ]; then
  PASS=$((PASS+1)); printf '  ok    [exit 2] BLOCK  commit attempted with require_approval_before_commit=false\n'
else
  FAIL=$((FAIL+1)); printf '  FAIL  [exit %s, want 2] commit with require_approval_before_commit=false\n' "$BYPASS_RC"
fi
case "$BYPASS_OUT" in
  *"does NOT disable this hook"*)
    PASS=$((PASS+1)); printf '  ok    refusal states the option is not a bypass\n' ;;
  *)
    FAIL=$((FAIL+1)); printf '  FAIL  refusal did not state that the option is not a bypass\n' ;;
esac

echo
echo "=== summary ==="
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

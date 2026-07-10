#!/usr/bin/env bash
# guard-destructive.sh -- PreToolUse(Bash) hook.
#
# Enforces the workspace's highest-priority rule:
#   NOTHING IS COMMITTED, COMMENTED, OR PUSHED WITHOUT EXPLICIT PER-ACTION
#   USER APPROVAL.
#
# THIS HOOK IS THE PRIMARY ENFORCEMENT LAYER, not a backstop.
#
# A Claude Code plugin CANNOT ship permission rules -- a plugin's settings.json
# honors only `agent` and `subagentStatusLine`, so the `permissions.deny` block
# that guards a hand-rolled .claude/ directory does not travel with the plugin.
# Everything therefore rests here. Nothing above this file is assumed.
#
# It also catches what deny rules structurally cannot: payloads inside
#   bash -c "...", eval, $( ), backticks, xargs, a heredoc, or a script the
# model just wrote. The command text is normalized first, so nesting and
# quoting do not hide the payload.
#
# There is deliberately NO bypass. The `require_approval_before_commit`
# userConfig option is read below only to state, explicitly, that setting it to
# false changes nothing.
#
# Protocol (docs: code.claude.com/docs/en/hooks):
#   stdin  = PreToolUse JSON, command at .tool_input.command
#   exit 2 = block, stderr shown to the model as feedback
#   exit 0 = no decision, normal permission flow continues
#
# Fails CLOSED: if the command cannot be parsed confidently, it is blocked.
# Compatible with bash 3.2 (macOS system bash).

set -u

RULE='BLOCKED by the k8s-contributor plugin (hooks/scripts/guard-destructive.sh).

Committing, pushing, and posting to GitHub require explicit per-action approval
from the user, given in words, for this exact action. This rule outranks any
plan, any review finding, any subagent instruction, and any earlier approval
for a different action.

THERE IS NO FLAG, SETTING, OR ENVIRONMENT VARIABLE THAT DISABLES THIS.
The plugin ships this hook as its enforcement layer; the
require_approval_before_commit option cannot turn it off, and neither can a
permissions allow-rule. Do NOT retry with a variant, a wrapper, a different
tool, or a script that runs it later -- every one of those is blocked too, and
attempting them is itself a violation of the rule.

What to do instead: write the proposed action to the run state directory
(artifacts/proposed-commits.md), print the exact command for the user to run
themselves, and stop. Handing the user a correct command IS the finished job.'

block() {
  printf '%s%s\n\nOffending command:\n  %s\n\nReason: %s\n' \
    "$RULE" "$NO_BYPASS_NOTE" "$RAW" "$1" >&2
  exit 2
}

# ---------------------------------------------------------------- read input
# Read the userConfig option only to say plainly that it is not a bypass. A
# user who set it to false gets told so at the moment it would have mattered.
NO_BYPASS_NOTE=""
if [ "${CLAUDE_PLUGIN_OPTION_REQUIRE_APPROVAL_BEFORE_COMMIT:-true}" = "false" ]; then
  NO_BYPASS_NOTE='
NOTE: require_approval_before_commit is set to false in this plugin'"'"'s config.
That option is documented as unsupported and it does NOT disable this hook.
The block above still applies. Remove the option or ignore it.'
fi

INPUT=$(cat)

if command -v jq >/dev/null 2>&1; then
  RAW=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  JQ_RC=$?
else
  JQ_RC=1
  RAW=""
fi

if [ "$JQ_RC" -ne 0 ]; then
  # No parser => cannot inspect the payload => refuse. Fail closed.
  RAW="<unparseable hook payload>"
  block "jq is unavailable, so the command could not be inspected."
fi

# Nothing to inspect (not a Bash call, or empty command): allow.
[ -n "$RAW" ] || exit 0

# ------------------------------------------------------------- normalization
# Goal: make nesting and quoting irrelevant, so that
#   bash -c "make test && git commit -am wip"
# and
#   git commit -am wip
# reduce to the same token stream.
#
# 1. strip backslash escapes
# 2. delete quote characters entirely (unwraps bash -c "...", $'...', etc.)
# 3. turn every shell separator/substitution marker into whitespace
# 4. collapse whitespace
NORM=$(printf '%s' "$RAW" \
  | tr '\n\r\t' '   ' \
  | sed -e 's/\\//g' \
        -e "s/[\"']/ /g" \
        -e 's/\$(/ /g' \
        -e 's/[`(){}]/ /g' \
        -e 's/&&/ /g' -e 's/||/ /g' \
        -e 's/|&/ /g' \
        -e 's/[;|&<>]/ /g' \
  | tr -s ' ')

# ------------------------------------------------- structurally opaque forms
# These can construct a blocked command at runtime from text this hook cannot
# see. Block them outright rather than guess.
case " $NORM " in
  *" eval "*)
      block "'eval' can construct a publishing command at runtime; this hook cannot inspect it. Split it into plain commands." ;;
  *" base64 "*|*" xxd "*|*" openssl enc "*)
      case " $NORM " in
        *" sh "*|*" bash "*|*" zsh "*)
          block "decode-then-execute pipeline cannot be inspected. Split it into plain commands." ;;
      esac ;;
esac

# git redirected at another checkout: -C / -c / --git-dir / --work-tree /
# --exec-path, or GIT_* environment overrides. Always blocked -- these are the
# documented way to reach a different repository and bypass path-based rules.
if printf '%s' "$NORM" | grep -Eq '(^| )git +(-C|-c|--git-dir|--work-tree|--exec-path)( |=)'; then
  block "'git -C/-c/--git-dir/--work-tree' can redirect git at another checkout."
fi
if printf '%s' "$NORM" | grep -Eq '(^| )(GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_CONFIG|GIT_CONFIG_GLOBAL|GIT_EDITOR|GIT_SEQUENCE_EDITOR|GIT_AUTHOR_NAME|GIT_COMMITTER_NAME)='; then
  block "GIT_* environment override can redirect git at another checkout or auto-approve an editor."
fi

# Writes into the git control directory (commit message, hooks).
if printf '%s' "$NORM" | grep -Eq '\.git/(COMMIT_EDITMSG|hooks/|config|MERGE_MSG|SQUASH_MSG)'; then
  block "writing inside .git/ (COMMIT_EDITMSG, hooks/, config) is a route to an unapproved commit."
fi

# Prow slash-commands, anywhere in the payload. These are how a comment
# mutates issue/PR state, so the text itself is treated as the action.
if printf '%s' "$NORM" | grep -Eq '(^| )/(triage|close|reopen|sig|kind|lgtm|approve|retest|test|hold|area|priority|assign|cc|milestone|release-note|release-note-none|remove-lifecycle|lifecycle|good-first-issue|help|override|skip)( |$)'; then
  block "the payload contains a Prow slash-command. Posting one mutates issue/PR state and requires explicit approval."
fi

# ------------------------------------------------------- token-level scanner
# Walks the normalized token stream. For each `git` / `gh` command word it
# resolves the real subcommand, skipping leading option flags. This is what
# lets `git stash push` through while blocking `git push`.
VERDICT=$(printf '%s\n' "$NORM" | awk '
function isflag(t) { return (substr(t,1,1) == "-") }

# One record, split on runs of whitespace (portable: default FS on $0).
{ n = split($0, tok, /[ \t]+/) }

END {
  for (i = 1; i <= n; i++) {
    t = tok[i]
    sub(/^.*\//, "", t)          # /usr/bin/git -> git

    # ---------------------------------------------------------------- git
    if (t == "git") {
      sub_ = ""
      for (j = i+1; j <= n; j++) {
        if (tok[j] == "") continue
        if (isflag(tok[j])) continue
        sub_ = tok[j]; break
      }
      if (sub_ == "commit" || sub_ == "push" || sub_ == "tag" ||
          sub_ == "rebase" || sub_ == "am"   || sub_ == "revert" ||
          sub_ == "cherry-pick" || sub_ == "filter-branch" ||
          sub_ == "filter-repo" || sub_ == "merge" || sub_ == "send-email" ||
          sub_ == "format-patch" || sub_ == "request-pull") {
        print "git " sub_; exit
      }
      # reset is only destructive with --hard / --merge / --keep
      if (sub_ == "reset") {
        for (j = i+1; j <= n; j++)
          if (tok[j] == "--hard" || tok[j] == "--merge" || tok[j] == "--keep") {
            print "git reset --hard"; exit
          }
      }
      # rewriting history via update-ref / symbolic-ref on HEAD
      if (sub_ == "update-ref" || sub_ == "fast-import") {
        print "git " sub_; exit
      }
    }

    # ----------------------------------------------------------------- gh
    if (t == "gh") {
      noun = ""; verb = ""
      for (j = i+1; j <= n; j++) {
        if (tok[j] == "") continue
        if (isflag(tok[j])) continue
        if (noun == "") { noun = tok[j]; continue }
        verb = tok[j]; break
      }
      # any mutating gh api call
      if (noun == "api") {
        for (j = i+1; j <= n; j++) {
          u = toupper(tok[j])
          if (u == "POST" || u == "PATCH" || u == "PUT" || u == "DELETE") {
            print "gh api (mutating method)"; exit
          }
          if (tok[j] == "--method" || tok[j] == "-X" || tok[j] == "-f" ||
              tok[j] == "-F" || tok[j] == "--field" || tok[j] == "--raw-field" ||
              tok[j] == "--input") {
            print "gh api (mutating method)"; exit
          }
        }
        # bare `gh api <path>` is a GET, but graphql can mutate
        if (verb == "graphql") { print "gh api graphql"; exit }
      }
      if (noun == "pr" || noun == "issue" || noun == "release" ||
          noun == "repo" || noun == "workflow" || noun == "run") {
        if (verb == "create" || verb == "comment" || verb == "close"  ||
            verb == "edit"   || verb == "merge"   || verb == "review" ||
            verb == "reopen" || verb == "delete"  || verb == "lock"   ||
            verb == "unlock" || verb == "transfer"|| verb == "pin"    ||
            verb == "unpin"  || verb == "ready"   || verb == "rerun"  ||
            verb == "upload" || verb == "sync"    || verb == "fork") {
          print "gh " noun " " verb; exit
        }
      }
    }
  }
  print ""
}')

if [ -n "$VERDICT" ]; then
  block "'$VERDICT' publishes or rewrites state."
fi

exit 0

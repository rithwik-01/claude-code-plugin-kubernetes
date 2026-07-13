# PRs, commits, review, OWNERS, release notes

Distilled from `community/contributors/guide/pull-requests.md`,
`guide/owners.md`, `guide/github-workflow.md`, `guide/release-notes.md`.
Read the source file before citing a specific rule.

## Commit messages

Subject + body, and the body is where the value is.

- Subject **≤50 characters** ideally, **never >72**.
- Capitalize the first word unless it starts with a lowercase identifier.
- **No trailing period** on the subject.
- **Imperative mood**: "Fix stale requestheader state", not "Fixed"/"Fixes".
- One blank line before the body; wrap the body at **72 characters**.
- Use the body to explain the **what and why**, not the how. It is the
  permanent record; PR comments are not.

### Two traps that get a PR auto-labelled `do-not-merge`

1. **Never put a GitHub keyword in a commit message.** These, followed by
   `#<issue>`, apply `do-not-merge/invalid-commit-message`:

   > `close` `closes` `closed` `fix` `fixes` `fixed` `resolve` `resolves` `resolved`

   `Fixes #12345` belongs in the **PR description**, never in the commit
   message. This is the single most common mistake in generated commits.
2. **No `@mentions` in commit messages** — they re-notify that person on every
   PR update.

Note the interaction with imperative mood: "Fix the leak" as a bare subject is
fine; "Fixes #123" is not, because of the issue reference.

## Pull request practices

- **Smaller is better.** Small commits, small PRs. A reviewer should be able to
  finish in one sitting.
- Open a **different** PR for unrelated fixes and generic refactors. Do not
  smuggle a cleanup into a bug fix.
- Do not open PRs that span the whole repository.
- Run local verifications before pushing (`make verify`, the relevant tests).
- Mark unfinished work as a draft, or prefix the title `WIP:`.
- Squash per the guide's squashing rules when asked by a reviewer.
- Comments matter: explain **why**, not what the code plainly says.

## The PR description

**Read the repo's own template from disk**; do not reproduce one from memory.
`kubernetes/kubernetes` → `.github/PULL_REQUEST_TEMPLATE.md`. Its current
sections:

```markdown
#### What type of PR is this?
/kind bug

#### What this PR does / why we need it:

#### Which issue(s) this PR is related to:
Fixes #<n>

#### Special notes for your reviewer:

#### Does this PR introduce a user-facing change?
```release-note
NONE
```

#### Additional documentation e.g., KEPs, usage docs, etc.:
```docs

```
```

plus trailing `/sig <sig>` and `/cc @<owner>` lines.

Kind labels available: `/kind bug`, `dependency`, `cleanup`, `documentation`,
`feature`; optionally `api-change`, `deprecation`, `failing-test`, `flake`,
`regression`.

> **`Fixes #<n>` is wrong for `kind/failing-test` and `kind/flake` PRs.** The
> template says so explicitly: a flake fix should not auto-close the flake
> issue, because the issue stays open to confirm the flake does not return.
> Reference the issue without the closing keyword instead.

## Release notes

- User-facing behavior or API change → a real release note in the
  ```` ```release-note ```` block.
- No user-facing change → literally `NONE` in the block.
- If users must act when upgrading, include the string **`action required`**.
- Keep it one sentence, written for a cluster operator reading a changelog —
  not for the reviewer of this diff.

## OWNERS and review

- `OWNERS` files list `approvers`, `reviewers`, and optionally `labels`.
  `OWNERS_ALIASES` expands team names.
- Two distinct acts: **`/lgtm`** (a reviewer says the code is correct) and
  **`/approve`** (an approver accepts it for the directory they own). Both are
  needed; they are usually different people.
- Find the right people by walking up from each changed file to the nearest
  `OWNERS`, then `/cc` them. `blunderbuss` also auto-assigns.
- The presence of your own name in an OWNERS file does not let you approve
  your own PR.

## Prow commands you will draft (but never post)

`/triage accepted` · `/sig <sig>` · `/kind <kind>` · `/priority <p>` ·
`/assign` · `/cc @user` · `/close` · `/reopen` · `/lgtm` · `/approve` ·
`/hold` · `/retest` · `/remove-lifecycle stale` · `/lifecycle frozen` ·
`/release-note-none` · `/help` · `/good-first-issue`

Full reference: <https://go.k8s.io/bot-commands>. Commands must be on their
own line at the start of the comment.

> Everything in this system stops at the draft. A `PreToolUse` hook blocks any
> shell command whose payload contains a Prow slash-command, and the
> `settings.json` deny rules block `gh pr create`, `gh issue comment`, and
> friends. If you believe a comment should be posted, print it and ask.

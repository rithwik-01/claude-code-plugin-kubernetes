# Adding a reviewer

The review fan-out is six agents. Adding a seventh is a deliberate act — see
the ceiling note at the bottom before you do it.

## 1. Create the agent file

Agents are **flat** in `plugins/k8s-contributor/agents/`. That is a convention
choice: a subdirectory becomes part of the scoped identifier, so
`agents/review/reviewer-x.md` would be addressed as
`k8s-contributor:review:reviewer-x`. Keeping them flat means the name in the
skill matches the filename.

```yaml
---
name: reviewer-<charter>
description: Use to review a Kubernetes diff for <trigger phrasing> - <the
  specific things this reviewer hunts for, so the model knows when to reach
  for it rather than a sibling reviewer>.
tools: Read, Grep, Glob, Bash
disallowedTools: Write, Edit, NotebookEdit
model: inherit
memory: true
skills:
  - k8s-contrib-guidelines
---
```

**Only these frontmatter fields are supported for plugin-shipped agents**:
`name`, `description`, `model`, `effort`, `maxTurns`, `tools`,
`disallowedTools`, `skills`, `memory`, `background`, `isolation`.

`hooks`, `mcpServers`, and `permissionMode` are **ignored** for plugin agents,
for security reasons. If your reviewer needs a hook, it goes in
`hooks/hooks.json` with a `SubagentStart`/`SubagentStop` matcher on the agent
name — not in the agent file. `color` is not supported either; it is silently
dropped.

The `description` is a **trigger**, not a summary. It is what the model reads
when deciding whether to invoke this agent, and it is the only part of the file
that costs tokens in every session.

## 2. Write the body

Four things, in this order:

1. **The charter** — one paragraph on what this reviewer is uniquely
   responsible for, and explicitly what it should leave to its siblings.
2. **An explicit checklist** — the things it must actually look at. A reviewer
   with a vague charter produces vague findings.
3. **The hard rules** — evidence is mandatory for every finding; `blocker` is
   reserved for the conditions the schema names, not for taste.
4. **A pointer to the JSON contract** at
   `${CLAUDE_PLUGIN_ROOT}/skills/k8s-verification-matrix/references/schemas.md`.

Read an existing reviewer first and match its shape. `reviewer-tests.md` is the
best model: it has the sharpest charter and the strictest evidence rule.

## 3. Wire it into the fan-out

Add it to the Phase 4 list in `skills/k8s-fix/SKILL.md`, scoped:

```
`k8s-contributor:reviewer-correctness` · ... · `k8s-contributor:reviewer-<charter>`
```

If the reviewer may write anything at all — even its own memory — add its name
to the confinement `case` in `hooks/scripts/guard-scope.sh`. Agents not listed
there fall through to the general workspace rule, which is more permissive than
a reviewer should be.

## 4. Test and release

```bash
plugins/k8s-contributor/hooks/scripts/test-hooks.sh   # confinement still holds
claude plugin validate ./plugins/k8s-contributor --strict
```

Then bump `version` in **both** `plugin.json` and `marketplace.json`, and add a
`CHANGELOG.md` entry. Users are pinned to the version string and receive
nothing until it changes.

## The ceiling

Keep the fan-out at **six or fewer**. If you add a seventh, drop one or run two
waves.

This is a review-quality limit, not a platform one — the platform's concurrent
subagent ceiling is far higher. Past about six, the synthesizer starts
spending its effort deduplicating overlapping findings rather than resolving
real contradictions, and the marginal reviewer mostly restates what a sibling
already said. If two reviewers keep producing the same findings, that is a sign
to merge them, not to add another.

# Structured hand-off contract

Defined once here. Every subagent in this system references this file and
returns **JSON only** — no prose before or after, no markdown fence.

## 1. Agent report (every subagent returns this)

```jsonc
{
  "agent": "reviewer-tests",            // must equal the agent's name
  "verdict": "pass",                    // pass | fail | blocked
  "confidence": "high",                 // high | medium | low
  "findings": [
    {
      "id": "T-01",                     // <AGENT-INITIAL>-<NN>, unique in this report
      "severity": "blocker",            // blocker | major | minor | nit
      "file": "pkg/kubelet/kubelet.go", // repo-relative; "" if not file-scoped
      "line": 1423,                     // 0 if not line-scoped
      "claim": "…what is wrong, in one sentence…",
      "evidence": "…command output, file:line, or doc citation that proves it…",
      "suggestion": "…concrete change…",
      "guideline_ref": "community/contributors/guide/coding-conventions.md#testing-conventions"
    }
  ],
  "notes": "…anything that is not a finding: context, caveats, what you could not check…",
  "memory_note": "…optional: a durable lesson about THIS repo worth keeping…"
}
```

### `memory_note` — durable learning without write access

The reviewers and `k8s-contributor:code-locator` declare `memory: true`, so they can **read**
accumulated notes from `${CLAUDE_PLUGIN_DATA}/agent-memory/<agent>/MEMORY.md` at startup. They
are also strictly read-only (`disallowedTools: Write, Edit, NotebookEdit`),
because a reviewer that can edit stops being a reviewer.

So durable learning flows back through this field instead of a direct write.
Put in `memory_note` only things that will still be true next run — a repo
convention, where a component lives, a recurring mistake in this package, a
command that does not work here. Not findings, not run-specific detail. Leave
it out when there is nothing worth keeping.

The resident thread appends accepted `memory_note` values to
`${CLAUDE_PLUGIN_DATA}/agent-memory/<agent>/MEMORY.md` at the end of the run, which is what
makes the next run cheaper.

### Field rules — these are enforced by the synthesizer, which drops violations

- **`verdict`**
  - `pass` — you checked your charter and found nothing at `blocker` or `major`.
  - `fail` — at least one `blocker` or `major` finding.
  - `blocked` — you could not do your job (missing input, tool unavailable,
    command would not run). Say exactly what you needed in `notes`.
    `blocked` is never silently treated as `pass`.
- **`evidence` is mandatory.** A finding without evidence is not a finding —
  drop it. Evidence is one of:
  - a `file:line` you actually read,
  - captured command output (quote the relevant lines),
  - a path under the run's `evidence/` directory,
  - a citation into `community/contributors/…` or an upstream doc.
  "It looks wrong" and "this is usually a problem" are not evidence.
- **"It compiles" / "tests pass"** may only be asserted with a referenced log
  path under the run's `evidence/` directory. Never assert either from reading
  the code.
- **`confidence: low`** is a legitimate answer. Report it rather than inflating
  a guess into a finding.

### `severity: blocker` is reserved

Exactly these, and nothing else:

| # | Blocker condition |
|---|---|
| 1 | Wrong root cause — the change does not address what actually produces the symptom |
| 2 | Workaround instead of a fix — symptom suppressed, invariant not restored |
| 3 | New external dependency (any `go.mod` / `go.sum` / `vendor/` change) |
| 4 | API or behavioral compatibility break |
| 5 | A test that does not actually fail without the fix |
| 6 | Data loss or a security regression |

Anything else is at most `major`. Do not inflate severity to force attention,
and never downgrade a real blocker to make a gate pass.

## 2. Triage synthesis verdict (`k8s-contributor:synthesizer`, phase 1b)

```jsonc
{
  "agent": "synthesizer",
  "phase": "triage",
  "verdict": "REAL",   // REAL | DUPLICATE | NOT-REPRODUCIBLE | WORKING-AS-INTENDED
                       // NEEDS-INFO | SUPPORT | ALREADY-FIXED
  "confidence": "high",
  "classification": "flake",       // bug|flake|regression|feature|docs|support|question
  "change_class": "flake",         // drives the gate set; see gates.md
  "sig": "sig/<area>",
  "component": "test/integration/<area>",
  "duplicate_of": null,            // "owner/repo#123" when verdict is DUPLICATE
  "fixed_by": null,                // "owner/repo#456" when verdict is ALREADY-FIXED
  "root_cause_hypothesis": "…one or two sentences, or null if not yet known…",
  "agent_agreement": [
    {"agent": "reproducer", "verdict": "reproduced", "weight": "decisive"}
  ],
  "contradictions": [
    {"between": ["behavior-adjudicator", "issue-analyst"],
     "sided_with": "behavior-adjudicator",
     "why": "cites the API convention text directly"}
  ],
  "missing_information": ["…questions for the reporter, empty if none…"],
  "proposed_prow_comment": "/triage accepted\n/sig node\n/kind flake",
  "next_step": "…what the user is being asked to approve…"
}
```

`proposed_prow_comment` is **drafted text only**. Posting it is the user's
call. Nothing in this system posts a comment.

## 3. Review synthesis (`k8s-contributor:synthesizer`, phase 5)

```jsonc
{
  "agent": "synthesizer",
  "phase": "review",
  "verdict": "fail",
  "blocker_count": 1,
  "major_count": 2,
  "minor_count": 4,
  "nit_count": 3,
  "actions": [                       // the single ordered action list
    {
      "rank": 1,
      "severity": "blocker",
      "from": ["reviewer-tests", "reviewer-correctness"],   // who raised it
      "claim": "…",
      "evidence": "…",
      "action": "…what the worker must do…",
      "cost": "small"                // small | medium | large
    }
  ],
  "deduplicated": [
    {"kept": "T-01", "merged": ["C-03"], "why": "same defect, two angles"}
  ],
  "contradictions": [
    {"between": ["reviewer-perf-security", "reviewer-maintainability"],
     "sided_with": "reviewer-perf-security",
     "why": "…"}
  ],
  "notes": "…"
}
```

The synthesizer **must not invent findings**. Every entry in `actions` traces
to at least one reviewer's finding via `from`.

## 4. Verifier report (phase 6)

```jsonc
{
  "agent": "verifier",
  "verdict": "fail",
  "gate_json": ".claude/k8s-contributor/state/<repo>/<issue>/gate.json",
  "overall_from_disk": "fail",       // copied verbatim from gate.json
  "failing_gates":  ["G2"],
  "missing_gates":  ["G7"],
  "deferred_gates": [
    {"id": "G6", "reason": "Linux-only", "ci_job": "pull-kubernetes-node-e2e-containerd"}
  ],
  "synthesis_blockers": 1,
  "synthesis_majors": 2,
  "may_report_pass": false,
  "why": "gate.json overall=fail and review-synthesis.md has 1 blocker"
}
```

**The verifier reads `gate.json`; it does not decide.** `may_report_pass` is
true only when *both* hold:

1. `gate.json` `overall == "pass"` — every applicable gate is `pass` with a
   non-empty evidence path, or `not-applicable`/`deferred-to-ci` with a stated
   reason (and, for `deferred-to-ci`, a named CI job); and
2. `review-synthesis.md` has zero `blocker` and zero `major` findings.

Anything else is FAIL. A verifier that reports PASS without both is broken.

## 5. Loop state (`loop.json`)

Persisted so `/k8s-fix` can be resumed in a later session.

```jsonc
{
  "run": "<repo>/<issue>",
  "repo": "kubernetes",
  "issue": 12345,
  "branch": "flake/12345-slug",
  "phase": "review",                 // intake|triage|plan|worker|review|verify|package|escalated
  "plan_loop":   {"round": 2, "max": 3, "last_verdict": "fail"},
  "review_loop": {"round": 1, "max": 3, "last_verdict": "fail"},
  "change_class": "flake",
  "escalated": false,
  "escalation_reason": null,
  "updated_at": "2026-08-02T19:00:00Z"
}
```

Both loops are bounded at **3 rounds**. On exhaustion set `escalated: true`,
write the human-escalation report, and stop. Never silently downgrade a
blocker to make the gate pass.

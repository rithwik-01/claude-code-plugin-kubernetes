## What this changes

<!-- One or two sentences. What and why, not how. -->

## Why

<!-- The problem this solves. If it fixes an issue, write: Fixes #<n> -->

## Checks

<!-- Run these locally; CI runs the same ones. -->

- [ ] `find . -name '*.sh' -not -path './.git/*' -exec bash -n {} \;` passes
- [ ] `bash plugins/k8s-contributor/hooks/scripts/test-hooks.sh` passes
- [ ] `bash scripts/prove-guardrails.sh` passes
- [ ] `claude plugin validate ./plugins/k8s-contributor --strict` passes

## Confirmations

- [ ] No new dependencies. Still bash 3.2 compatible, plus `jq`
- [ ] No absolute or personal paths added
- [ ] The approval guarantee is unchanged: the plugin still cannot commit,
      comment, or push on its own

<!--
If this is a release, also confirm:
  - version bumped in plugin.json AND marketplace.json
  - CHANGELOG.md entry added for that version
-->

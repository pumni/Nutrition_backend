# Handoff Report <WO-ID>

Status: `HANDOFF`

## Implementation identity

- Work order: `<WO-ID>`
- Branch: `<branch>`
- Base commit observed: `<sha>`
- Final commit: `<sha>`

## What changed

<Concise implementation summary.>

Changed files:

- `<path>` — <reason>

## Acceptance-criteria mapping

- [ ] Criterion 1 — <evidence>
- [ ] Criterion 2 — <evidence>
- [ ] Negative/failure-path criterion — <evidence>

Unchecked criteria mean the task is not ready for acceptance.

## Verification

| Gate / command | Status | Evidence / relevant result |
|---|---|---|
| `<gate-id or command>` | PASS / FAIL / SKIPPED | `<concise evidence>` |

For every `SKIPPED`, explain why it could not run and whether CI is expected to cover it.

## Final diff inspection

- `git diff --check`: `<result>`
- `git diff --stat`: `<result>`
- `git status`: `<result>`
- Unrelated changes found: `NO` / `<details>`

## Protected-decision check

Protected decision required beyond approvals: `NO` / `YES`

If `YES`, stop affected work and document:

- classification;
- repository evidence;
- constraint;
- implementation impact;
- smallest decision required.

## Risks / follow-ups

- `<residual risk or NONE>`

## Codex declaration

I am handing off implementation evidence for reviewer evaluation. I am **not** declaring this work accepted and I have not merged it.

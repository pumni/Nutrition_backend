# Work Order <WO-ID>: <Short title>

Status: `ASSIGNED`

## Objective

<One concrete outcome.>

## Context

<Why this work is needed and relevant issue/PR/roadmap references.>

## Baseline

- Repository: `pumni/Nutrition_backend`
- Expected base branch: `<branch>`
- Expected baseline commit: `<sha or "latest approved base">`
- Assigned implementation branch: `<branch>`

If the local branch/baseline materially differs, stop mutation and report the mismatch.

## Write boundary

Allowed coarse paths:

- `<implementation-path/**>`
- `.codex/reports/<WO-ID>-handoff.md`

Optional work-order status update, only when explicitly permitted by the reviewer:

- `.codex/work-orders/<WO-ID>.md`

Anything outside the listed boundary requires explicit scope expansion before editing. There is no implicit exception for task artifacts.

## Acceptance criteria

- [ ] <Observable criterion 1>
- [ ] <Observable criterion 2>
- [ ] <Failure/negative-path criterion>
- [ ] Required repository verification passes for the actual diff.
- [ ] Final diff contains no unrelated changes.

## Non-negotiables

- <Invariant or behavior that must remain unchanged.>
- Do not weaken fail-closed behavior, tests, validation, authorization, provenance, or immutability to satisfy the task.
- Do not merge.

## Protected approvals

Explicitly approved protected decisions for this task:

- `NONE`

Anything protected but absent here remains unapproved.

## Known blockers/dependencies

- <Issue/PR/decision or NONE>

## Investigation expectations

- <Files/modules/contracts Codex should inspect before editing, without forcing an implementation.>

## Verification expectations

Suggested gates/commands based on known scope:

- `<gate-id or command>`

These are not exhaustive. The actual diff determines mandatory canonical verification.

## Handoff evidence required

Codex must provide:

- final commit SHA;
- changed-file summary;
- acceptance-criteria mapping;
- gate/test results with failures/skips explained;
- protected-decision check;
- known residual risks;
- path to `.codex/reports/<WO-ID>-handoff.md`.

## Reviewer

Coordinator/reviewer: ChatGPT in the controlling conversation.

Human repository owner retains merge/release authority.

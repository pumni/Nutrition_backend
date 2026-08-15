# Work Orders

Work orders are issued by the coordinating reviewer and executed by local Codex CLI.

## Naming

Use:

`WO-YYYYMMDD-NNN-short-slug.md`

Example:

`WO-20260815-001-fix-fdc-importer-ci.md`

The ID is immutable once assigned.

## Lifecycle

- `DRAFT` — reviewer is preparing the task; Codex must not execute it.
- `ASSIGNED` — executable when referenced by `.codex/CURRENT_TASK.md`.
- `IN_PROGRESS` — local implementation is underway.
- `HANDOFF` — implementation committed and evidence returned for review.
- `CHANGES_REQUESTED` — reviewer found blocking defects; same work order remains active.
- `ACCEPTED` — reviewed commit satisfies the work order.
- `BLOCKED_PROTECTED_DECISION` — owner decision required before correct continuation.
- `CANCELLED` — no further work.

Only one work order should be referenced by `CURRENT_TASK.md` at a time unless the human owner explicitly adopts a parallel-work protocol.

## Ownership

The reviewer controls assignment text and acceptance criteria. Codex may update implementation-status/evidence sections only when the work order explicitly allows it; Codex must not rewrite the objective, write boundary, protected approvals, or acceptance criteria to match its implementation.

Completed work orders are retained as engineering history. Do not place secrets or machine-local credentials in them.

# Local Codex CLI Control Folder

This folder is the operating contract for **Codex CLI running in the user's local checkout**.

## Roles

- **Coordinator / reviewer:** ChatGPT in the coordinating conversation. It issues bounded work orders, reviews implementation evidence, requests corrections, and records acceptance.
- **Implementer:** Codex CLI running locally. It investigates, edits, tests, commits, and produces a handoff report.
- **Human repository owner:** retains final authority over protected product/domain/architecture/database/security/provider/release decisions and over merge/release actions.

This split does not override repository governance. Root `AGENTS.md`, `.agent/manifest.json`, `.agent/authority/`, `.agent/context/router.json`, and `.agent/maps/verification-map.json` remain authoritative.

## Start here on the local machine

From the repository root:

```text
git status
git pull --ff-only
codex
```

Then instruct Codex:

```text
Read AGENTS.md, .codex/README.md, .codex/PROTOCOL.md, and .codex/CURRENT_TASK.md.
If CURRENT_TASK is NONE, do not modify repository files.
If a work order is assigned, execute it exactly within its write boundary.
Investigate before editing, do not invent protected decisions, run all canonical gates required by the final diff, commit the work, and produce the required handoff report.
```

Codex supports repository guidance through `AGENTS.md`; run it from the repository root so repository-level guidance is in scope.

## Operating loop

1. ChatGPT creates/updates a work order under `.codex/work-orders/` and points `.codex/CURRENT_TASK.md` to it.
2. User pulls the task to the local checkout.
3. Local Codex executes the work order on the assigned branch.
4. Codex runs required verification, commits, and writes a handoff report.
5. User pushes the branch/PR and tells ChatGPT the task is ready for review.
6. ChatGPT reviews the actual diff, CI, tests, scope, and protected-decision compliance.
7. ChatGPT either records `CHANGES_REQUESTED` with concrete defects or `ACCEPTED` in an acceptance report.
8. Human repository owner decides whether/when to merge or release.

## State machine

`DRAFT -> ASSIGNED -> IN_PROGRESS -> HANDOFF -> CHANGES_REQUESTED -> HANDOFF -> ACCEPTED`

Alternative terminal states: `BLOCKED_PROTECTED_DECISION` or `CANCELLED`.

Codex may declare `HANDOFF`; it must never self-declare `ACCEPTED`.

## Folder layout

- `CURRENT_TASK.md` — pointer to the single active assignment.
- `PROTOCOL.md` — assignment, execution, evidence, review, and acceptance rules.
- `templates/WORK_ORDER.md` — template used by ChatGPT when assigning work.
- `templates/HANDOFF_REPORT.md` — report Codex must return after implementation.
- `templates/ACCEPTANCE_REPORT.md` — reviewer acceptance/rejection record.
- `work-orders/README.md` — work-order naming/lifecycle.
- `reports/README.md` — handoff and acceptance record naming.

Never store secrets, tokens, credentials, production data, or sensitive machine-specific paths here.

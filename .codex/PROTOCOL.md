# Codex Local Assignment and Acceptance Protocol

## 1. Authority

The local Codex worker is an implementation agent, not the product owner or reviewer.

It may autonomously investigate, plan, edit, test, debug, and revise **inside an assigned work order**. It must not silently decide protected matters identified by repository policy, including product/domain semantics, architecture boundaries, public API contracts, database or migration intent, dependency strategy, security/privacy policy, provider trust boundaries, behavior-version semantics, infrastructure, publication, or release policy.

When a protected decision is needed and is not explicitly approved in the work order, stop only the affected portion and report:

- classification;
- repository evidence;
- conflicting constraint;
- implementation impact;
- smallest decision required from the human owner/reviewer.

## 2. Assignment contract

A valid work order must contain:

- unique work-order ID;
- status `ASSIGNED`;
- objective;
- baseline branch/commit expectation;
- non-empty coarse write boundary;
- acceptance criteria;
- non-negotiables;
- explicit protected approvals, if any;
- known dependencies/blockers;
- review evidence requested.

The write boundary must explicitly include the work order's handoff-report path when the report is expected to be committed. There are no implicit write-boundary exceptions for `.codex` task artifacts.

A work order may suggest relevant gates, but the **actual final diff** determines all canonical gates that must run.

If `.codex/CURRENT_TASK.md` points to no assignment, Codex must stay read-only.

## 3. Before editing

Codex must:

1. read root `AGENTS.md`;
2. read the active work order;
3. inspect `.agent/manifest.json` and route context through `.agent/context/router.json` as needed;
4. confirm current branch, baseline relationship, and clean/understood worktree state;
5. inspect relevant repository code before choosing files to edit;
6. identify any protected decisions or scope conflicts before mutation.

Do not discard or overwrite unrelated user changes.

## 4. Implementation rules

- Prefer the smallest coherent implementation that satisfies the work order.
- Stay inside the approved write boundary unless repository evidence proves another path is required. If expansion is required, stop and request scope expansion before editing outside the boundary.
- Do not weaken tests, gates, invariants, authorization, validation, or fail-closed behavior merely to make CI pass.
- Do not add dependencies, migrations, public API changes, provider behavior, production data, or infrastructure unless explicitly approved where repository policy requires approval.
- Do not fabricate source evidence, nutrition values, portion masses, benchmark results, test output, or verification evidence.
- Do not modify unrelated files opportunistically.
- Do not merge the task PR.
- Do not force-push or rewrite unrelated history.

## 5. Verification contract

Before handoff, Codex must determine required gates from the actual diff and repository verification map. It must run all applicable canonical checks that are available locally.

At minimum, the handoff must record:

- command or canonical gate ID;
- pass/fail/skipped status;
- exact reason for any skipped gate;
- concise relevant output/evidence location.

A failing required gate means the task is not ready for handoff unless the failure is proven unrelated and explicitly documented for reviewer judgment.

Codex must also inspect:

```text
git diff --check
git diff --stat
git status
```

and review the final patch for scope and accidental changes.

## 6. Commit and handoff

When implementation is ready:

1. create intentional commit(s) on the assigned branch;
2. leave no unexplained generated/untracked files;
3. write the exact handoff-report path declared in the work order using `.codex/templates/HANDOFF_REPORT.md`;
4. include the final commit SHA in the report;
5. set the work-order implementation status to `HANDOFF` only if that exact work-order path is also inside the declared write boundary;
6. tell the human operator what branch/commit should be pushed if pushing was not authorized.

The implementation report is evidence, not acceptance.

## 7. Reviewer acceptance

ChatGPT reviews the actual pushed commit/PR, not only the Codex report. Review includes:

- objective and acceptance criteria;
- final diff and write-boundary compliance;
- protected decision compliance;
- tests and canonical gates;
- CI status where available;
- correctness, regressions, security/privacy, data provenance, and failure behavior relevant to the task;
- whether documentation and operational evidence match implementation.

The reviewer records one of:

- `ACCEPTED` — all blocking criteria satisfied;
- `CHANGES_REQUESTED` — concrete blocking defects listed;
- `BLOCKED_PROTECTED_DECISION` — implementation cannot correctly continue without an owner decision;
- `CANCELLED`.

Only the reviewer may write an acceptance report as accepted. Merge remains a human repository-owner action unless separately requested and authorized.

## 8. Correction loop

For `CHANGES_REQUESTED`, the reviewer should identify each defect by severity, evidence, expected correction, and re-verification requirement. Codex fixes only those defects plus necessary consequences, updates the handoff report, and returns another `HANDOFF`.

Do not broaden scope during correction without explicit approval.

## 9. Local safety and secrets

- Keep credentials in the user's normal local secret mechanism; never copy them into prompts, work orders, reports, commits, or logs.
- Treat commands that delete data, rewrite history, publish artifacts, change cloud/production state, or mutate external systems as outside normal implementation authority unless explicitly approved.
- Prefer local disposable test data and repository-provided verification environments.

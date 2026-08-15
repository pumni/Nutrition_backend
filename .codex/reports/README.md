# Codex Task Reports

This directory stores implementation handoff and reviewer acceptance records.

## Naming

For work order `WO-YYYYMMDD-NNN-slug`:

- Codex handoff: `WO-YYYYMMDD-NNN-slug-handoff.md`
- Reviewer acceptance: `WO-YYYYMMDD-NNN-slug-acceptance.md`

For a correction cycle, update the same handoff report with a clearly dated/revisioned section rather than creating ambiguous competing reports, unless the work order requests immutable per-attempt evidence.

## Trust model

A handoff report is self-reported implementation evidence and is not sufficient for acceptance by itself. The reviewer checks the actual pushed commit/PR and CI/test evidence.

An acceptance report records the review decision for a specific commit SHA. If code changes after an `ACCEPTED` SHA, that acceptance no longer covers the new commit and must be reviewed again.

Do not store secrets, API keys, tokens, production credentials, or sensitive user data in reports.

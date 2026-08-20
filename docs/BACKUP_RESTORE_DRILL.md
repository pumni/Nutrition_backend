# Backup, restore, and rollback drill

Status: staging-preparation contract; production activation is not authorized.

This runbook implements OWNER-BE-005. PostgreSQL recovery uses encrypted daily backups and
continuous WAL/PITR where the selected platform supports it, with a 15-minute RPO objective,
4-hour RTO objective, 35-day backup retention, monthly staging restore drills, and at least
quarterly restore drills from production backup copies. The platform owner must still configure
the actual backup service, encryption keys, storage, access controls, WAL archive, and secret
manager. The repository does not guess those infrastructure choices.

## Isolated local/staging-safe drill

The deterministic drill script uses only the repository's local PostgreSQL Compose service as a
source and a fresh, disposable PostgreSQL container as the restore target. It writes both the
custom-format backup and JSON evidence outside the repository. It rejects repository paths for
those artifacts and contains no production connection-string input.

```powershell
$evidence = Join-Path $env:TEMP "nutrition-p2-105-recovery-evidence.json"
$backup = Join-Path $env:TEMP "nutrition-p2-105-recovery.dump"
pwsh -NoLogo -NoProfile -File .\scripts\run-backup-restore-drill.ps1 `
  -OutputPath $evidence `
  -BackupPath $backup `
  -InitializeFoundation
Get-Content -Raw $evidence
```

The script performs the following bounded checks:

- starts the local PostgreSQL service when it is not supplied with `-UseExistingSource`;
- creates a PostgreSQL custom-format dump without placing it in the repository;
- restores the dump into a new isolated PostgreSQL 18 container;
- compares migration, analysis, catalog, audit, job, and outbox row snapshots;
- verifies no restored analysis row contains `raw_text_ciphertext`;
- starts the API against the restored database and checks readiness plus an owner-scoped listing;
- records backup/restore duration, artifact SHA-256, and objective comparisons;
- removes the disposable restore container and stops only the source service it started.

The observed local RPO is reported as zero rows omitted from the logical backup snapshot. This is
useful evidence for the tested dump/restore boundary, but it is not a claim that the platform's
continuous WAL/PITR archive has been tested. The measured local RTO is the end-to-end duration
through restore and API checks; it must be reviewed against the 4-hour objective together with
platform-specific staging evidence.

## Platform implementation requirements

Before staging is considered recoverable, the platform owner must bind the following to the
candidate release and retain the references in the release evidence:

1. Backup job schedule, WAL/PITR archive health, encryption-at-rest and in-transit settings.
2. Backup retention policy of 35 days and access restricted to the recovery operators.
3. A disposable restore target isolated from production traffic and credentials.
4. A restore sequence that reapplies deletion and retention tombstones before serving any
   restored user data. Deleted user data may remain in encrypted backups until expiry.
5. Evidence of the measured RPO/RTO, application-level checks, and the exact backup artifact or
   platform run reference.

## Rollback boundaries

The versioned plan is [deploy/recovery/rollback-plan.json](../deploy/recovery/rollback-plan.json).
Application rollback selects the prior accepted image digest and reviewed configuration
fingerprint. It never copies secret values into evidence. Database recovery is forward-only:
restore a compatible backup and deploy the compatible application; do not mutate or reverse
applied migrations.

Catalog rollback creates a new staged immutable snapshot from the prior superseded release through
the existing catalog rollback workflow. It recomputes the manifest checksum, validates membership
and evidence, and uses the explicit catalog activation gate. The drill does not activate a catalog,
deploy an image, change traffic, call the hosted provider, or authorize a release.

## Required review before production

The drill artifact alone does not close OWNER-BE-006. Production remains blocked until provider
privacy, benchmark, `production_eligible` catalog evidence, staging SLO/load/restore review, and
release/rollback gates are all accepted by the owner.

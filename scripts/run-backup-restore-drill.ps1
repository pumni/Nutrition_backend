[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [string]$ComposeFile = (Join-Path $PSScriptRoot "..\deploy\compose.yaml"),
    [string]$PostgresImage = "postgres:18",
    [int]$TargetPort = 55432,
    [switch]$UseExistingSource,
    [switch]$InitializeFoundation
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repositoryPrefix = $repositoryRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$composeFullPath = (Resolve-Path -LiteralPath $ComposeFile).Path
$targetName = "nutrition-recovery-$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
$targetBackupName = "nutrition-recovery.dump"
$sourceStarted = $false
$targetStarted = $false
$apiProcess = $null
$failureMessage = $null
$success = $false
$drillTimer = [Diagnostics.Stopwatch]::StartNew()

function Assert-ExternalPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be outside the repository"
    }
    return $fullPath
}

function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $output = @(& docker @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($output -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = "docker exited with code $LASTEXITCODE"
        }
        throw "$Label failed: $details"
    }
    return $output
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Program,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $output = @(& $Program @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($output -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = "$Program exited with code $LASTEXITCODE"
        }
        throw "$Label failed: $details"
    }
    return $output
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label
    )

    return Invoke-Docker -Arguments (@("compose", "-f", $composeFullPath) + $Arguments) -Label $Label
}

function Get-SourceContainer {
    $lines = @(Invoke-Compose -Arguments @("ps", "-q", "postgres") -Label "locate source PostgreSQL container")
    $container = (($lines -join "`n").Trim())
    if ([string]::IsNullOrWhiteSpace($container)) {
        throw "source PostgreSQL container was not found"
    }
    return $container
}

function Invoke-DbJson {
    param(
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$Query
    )

    $lines = @(Invoke-Docker -Arguments @(
            "exec", $Container, "psql", "-At", "-v", "ON_ERROR_STOP=1",
            "-U", "nutrition", "-d", "nutrition", "-c", $Query
        ) -Label "query restored application invariants")
    $text = (($lines -join "`n").Trim())
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "database invariant query returned no result"
    }
    try {
        return $text | ConvertFrom-Json
    }
    catch {
        throw "database invariant query returned invalid JSON"
    }
}

function Invoke-DbScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $lines = @(Invoke-Docker -Arguments @(
            "exec", $Container, "psql", "-At", "-v", "ON_ERROR_STOP=1",
            "-U", "nutrition", "-d", "nutrition", "-c", $Query
        ) -Label $Label)
    return (($lines -join "`n").Trim())
}

function Get-DatabaseSnapshot {
    param([Parameter(Mandatory = $true)][string]$Container)

    $query = @"
SELECT json_build_object(
    'migration_count', (SELECT count(*) FROM _sqlx_migrations),
    'analysis_count', (SELECT count(*) FROM analysis.meal_analysis),
    'catalog_release_count', (SELECT count(*) FROM catalog.catalog_release),
    'active_catalog_release_count', (SELECT count(*) FROM catalog.catalog_release WHERE status = 'active'),
    'raw_text_ciphertext_rows', (SELECT count(*) FROM analysis.meal_analysis WHERE raw_text_ciphertext IS NOT NULL),
    'audit_event_count', (SELECT count(*) FROM ops.audit_event),
    'job_count', (SELECT count(*) FROM ops.job),
    'outbox_event_count', (SELECT count(*) FROM ops.outbox_event)
)::text;
"@
    return Invoke-DbJson -Container $Container -Query $query
}

function Assert-SnapshotMatches {
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual
    )

    foreach ($property in @(
            "migration_count",
            "analysis_count",
            "catalog_release_count",
            "active_catalog_release_count",
            "raw_text_ciphertext_rows",
            "audit_event_count",
            "job_count",
            "outbox_event_count"
        )) {
        if ([int64]$Expected.$property -ne [int64]$Actual.$property) {
            throw "restore invariant mismatch for $property"
        }
    }
    if ([int64]$Actual.raw_text_ciphertext_rows -ne 0) {
        throw "restored database contains raw meal text ciphertext rows"
    }
}

function Set-ProcessEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Values)

    $previous = @{}
    foreach ($key in $Values.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$Values[$key], "Process")
    }
    return $previous
}

function Restore-ProcessEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Previous)

    foreach ($key in $Previous.Keys) {
        [Environment]::SetEnvironmentVariable($key, $Previous[$key], "Process")
    }
}

function Start-RestoredApi {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$MetricsPort
    )

    $binaryName = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        "api-http.exe"
    }
    else {
        "api-http"
    }
    $binaryPath = Join-Path $repositoryRoot "target\debug\$binaryName"
    if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
        Invoke-Native -Program "cargo" -Arguments @("build", "-p", "api-http", "--quiet") -Label "build API for restored-database check" | Out-Null
    }
    if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
        throw "API binary was not produced for restored-database check"
    }

    $environment = @{
        "APP_ENV" = "ci"
        "DATABASE_URL" = "postgres://nutrition:nutrition@127.0.0.1:$TargetPort/nutrition"
        "AUTH_MODE" = "development"
        "PARSER_MODE" = "fixture"
        "APP_BIND_ADDR" = "127.0.0.1:$Port"
        "API_METRICS_BIND_ADDR" = "127.0.0.1:$MetricsPort"
        "RUST_LOG" = "error"
    }
    $previous = Set-ProcessEnvironment -Values $environment
    try {
        $startParameters = @{
            FilePath = $binaryPath
            PassThru = $true
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $startParameters.WindowStyle = "Hidden"
        }
        $process = Start-Process @startParameters
    }
    finally {
        Restore-ProcessEnvironment -Previous $previous
    }
    return $process
}

function Wait-ApiReady {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri "$BaseUrl/health/ready" -TimeoutSec 2
            if ($response.status -eq "ready") {
                return $response
            }
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    throw "restored API did not become ready"
}

function Write-Evidence {
    param([Parameter(Mandatory = $true)][object]$Evidence)

    $parent = Split-Path -Parent $OutputFullPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputFullPath -Encoding utf8
}

$OutputFullPath = Assert-ExternalPath -Path $OutputPath -Label "OutputPath"
$BackupFullPath = Assert-ExternalPath -Path $BackupPath -Label "BackupPath"
if ($TargetPort -lt 1024 -or $TargetPort -gt 65535) {
    throw "TargetPort must be a non-privileged TCP port"
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker is required for the isolated backup/restore drill"
}

$sourceContainer = $null
$sourceSnapshot = $null
$restoredSnapshot = $null
$backupSha256 = $null
$backupBytes = $null
$backupDurationSeconds = $null
$restoreDurationSeconds = $null
$applicationChecks = [ordered]@{}
$rollbackPlanPath = Join-Path $repositoryRoot "deploy\recovery\rollback-plan.json"
$rollbackPlanSha256 = $null

try {
    if (-not (Test-Path -LiteralPath $rollbackPlanPath -PathType Leaf)) {
        throw "rollback plan is missing: deploy/recovery/rollback-plan.json"
    }
    $rollbackPlanSha256 = (Get-FileHash -LiteralPath $rollbackPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()

    if (-not $UseExistingSource) {
        Invoke-Compose -Arguments @("up", "-d", "--wait", "postgres") -Label "start local source PostgreSQL" | Out-Null
        $sourceStarted = $true
    }
    $sourceContainer = Get-SourceContainer
    Invoke-Docker -Arguments @("exec", $sourceContainer, "pg_isready", "-U", "nutrition", "-d", "nutrition") -Label "check source PostgreSQL" | Out-Null

    if ($InitializeFoundation) {
        $workerEnvironment = @{
            "APP_ENV" = "ci"
            "DATABASE_URL" = "postgres://nutrition:nutrition@127.0.0.1:5432/nutrition"
            "RUN_MIGRATIONS" = "true"
            "RUN_FOUNDATION_SEED" = "true"
            "WORKER_MODE" = "idle"
        }
        $previous = Set-ProcessEnvironment -Values $workerEnvironment
        try {
            Invoke-Native -Program "cargo" -Arguments @("run", "-p", "worker", "--quiet") -Label "initialize local foundation source" | Out-Null
        }
        finally {
            Restore-ProcessEnvironment -Previous $previous
        }
    }

    $sourceSnapshot = Get-DatabaseSnapshot -Container $sourceContainer

    $backupDirectory = Split-Path -Parent $BackupFullPath
    if (-not (Test-Path -LiteralPath $backupDirectory)) {
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $BackupFullPath) {
        Remove-Item -LiteralPath $BackupFullPath -Force
    }

    $backupTimer = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Docker -Arguments @("exec", $sourceContainer, "rm", "-f", "/tmp/$targetBackupName") -Label "clear source backup scratch path" | Out-Null
    Invoke-Docker -Arguments @(
        "exec", $sourceContainer, "pg_dump", "-U", "nutrition", "-d", "nutrition", "-Fc", "-f", "/tmp/$targetBackupName"
    ) -Label "create local PostgreSQL backup" | Out-Null
    Invoke-Docker -Arguments @(
        "cp", ("{0}:/tmp/{1}" -f $sourceContainer, $targetBackupName), $BackupFullPath
    ) -Label "copy backup artifact outside repository" | Out-Null
    $backupTimer.Stop()
    $backupDurationSeconds = [Math]::Round($backupTimer.Elapsed.TotalSeconds, 3)
    $backupSha256 = (Get-FileHash -LiteralPath $BackupFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $backupBytes = (Get-Item -LiteralPath $BackupFullPath).Length
    if ($backupBytes -le 0) {
        throw "backup artifact is empty"
    }

    Invoke-Docker -Arguments @(
        "run", "-d", "--name", $targetName,
        "-e", "POSTGRES_DB=nutrition",
        "-e", "POSTGRES_USER=nutrition",
        "-e", "POSTGRES_PASSWORD=nutrition",
        "-p", "$TargetPort`:5432",
        $PostgresImage
    ) -Label "start isolated restore PostgreSQL" | Out-Null
    $targetStarted = $true
    $targetReady = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            Invoke-Docker -Arguments @("exec", $targetName, "pg_isready", "-U", "nutrition", "-d", "nutrition") -Label "check isolated restore PostgreSQL" | Out-Null
            $targetReady = $true
            break
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    if (-not $targetReady) {
        throw "isolated restore PostgreSQL did not become ready"
    }

    Invoke-Docker -Arguments @("cp", $BackupFullPath, ("{0}:/tmp/{1}" -f $targetName, $targetBackupName)) -Label "copy backup into isolated restore" | Out-Null
    $restoreTimer = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Docker -Arguments @(
        "exec", $targetName, "pg_restore", "--exit-on-error", "--clean", "--if-exists", "--no-owner",
        "-U", "nutrition", "-d", "nutrition", "/tmp/$targetBackupName"
    ) -Label "restore PostgreSQL backup into isolated database" | Out-Null
    $restoreTimer.Stop()
    $restoreDurationSeconds = [Math]::Round($restoreTimer.Elapsed.TotalSeconds, 3)

    $restoredSnapshot = Get-DatabaseSnapshot -Container $targetName
    Assert-SnapshotMatches -Expected $sourceSnapshot -Actual $restoredSnapshot
    $applicationChecks["schema_and_row_snapshot"] = "passed"
    $applicationChecks["raw_text_ciphertext_absent"] = ([int64]$restoredSnapshot.raw_text_ciphertext_rows -eq 0)
    $applicationChecks["migration_inventory_unchanged"] = ([int64]$sourceSnapshot.migration_count -eq [int64]$restoredSnapshot.migration_count)

    $apiPort = $TargetPort + 1000
    $metricsPort = $TargetPort + 2000
    $apiProcess = Start-RestoredApi -Port $apiPort -MetricsPort $metricsPort
    try {
        $baseUrl = "http://127.0.0.1:$apiPort"
        $readiness = Wait-ApiReady -BaseUrl $baseUrl
        $applicationChecks["api_readiness"] = if ($readiness.status -eq "ready") { "passed" } else { "failed" }
        $list = Invoke-RestMethod -Uri "$baseUrl/v1/nutrition/analyses" -Headers @{ Authorization = "Bearer dev:0198f100-0000-7000-8000-000000000098" } -TimeoutSec 5
        if ($null -eq $list) {
            throw "owner-scoped analysis listing returned no response"
        }
        $applicationChecks["owner_scoped_analysis_read"] = "passed"
    }
    finally {
        if ($apiProcess -and -not $apiProcess.HasExited) {
            Stop-Process -Id $apiProcess.Id -Force
        }
        $apiProcess = $null
    }

    $drillTimer.Stop()
    $rtoObservedMinutes = [Math]::Round($drillTimer.Elapsed.TotalMinutes, 3)
    $success = $true
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    if ($apiProcess -and -not $apiProcess.HasExited) {
        Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($targetStarted) {
        docker rm -f $targetName 2>$null | Out-Null
    }
    if ($sourceStarted) {
        try {
            Invoke-Compose -Arguments @("stop", "postgres") -Label "stop local source PostgreSQL" | Out-Null
        }
        catch {
            if ($null -eq $failureMessage) {
                $failureMessage = $_.Exception.Message
            }
            $success = $false
        }
    }
}

$evidence = [ordered]@{
    schema_version = "backup-restore-drill-evidence-0.1.0"
    evidence_kind = "isolated-local-recovery-drill"
    status = if ($success) { "passed" } else { "failed" }
    decision_boundary = "Staging preparation evidence only; production data, production credentials, production deployment, catalog activation, and traffic activation were not used or authorized."
    owner_decision = "OWNER-BE-005"
    production_data_used = $false
    production_credentials_used = $false
    production_activation_performed = $false
    provider_called = $false
    migration_mutation = "none"
    source = [ordered]@{
        compose_file = "deploy/compose.yaml"
        service = "postgres"
        host_class = "local-loopback"
    }
    backup = [ordered]@{
        format = "postgresql-custom"
        bytes = $backupBytes
        sha256 = $backupSha256
        duration_seconds = $backupDurationSeconds
        artifact_path_external_to_repository = $true
    }
    restore = [ordered]@{
        isolated_container = $true
        postgres_image = $PostgresImage
        duration_seconds = $restoreDurationSeconds
        application_checks = $applicationChecks
        source_snapshot = $sourceSnapshot
        restored_snapshot = $restoredSnapshot
    }
    recovery_objectives = [ordered]@{
        rpo_objective_minutes = 15
        rpo_observed_minutes = if ($success) { 0 } else { $null }
        rpo_observation = "Logical backup snapshot replayed all source snapshot rows in the isolated drill; this does not certify continuous WAL/PITR platform behavior."
        rto_objective_hours = 4
        rto_observed_minutes = if ($success) { $rtoObservedMinutes } else { $null }
        rto_within_objective = if ($success) { $rtoObservedMinutes -le 240 } else { $false }
    }
    policy = [ordered]@{
        backup_schedule = "daily plus continuous WAL/PITR where platform supports it"
        retention_days = 35
        encryption = "required at rest and in transit; platform key/access policy remains owner-controlled"
        restore_tombstones_before_serve = $true
        staging_restore_frequency = "monthly"
        production_backup_restore_frequency = "at least quarterly from production backup copies"
    }
    rollback = [ordered]@{
        plan_path = "deploy/recovery/rollback-plan.json"
        plan_sha256 = $rollbackPlanSha256
        application_image_config = "documented and staging-gated; no deployment performed"
        catalog_release = "new staged rollback snapshot through existing immutable release workflow; no activation performed"
        migrations = "forward-only; restore/redeploy previous compatible application before applying newer migrations; never mutate applied migrations"
    }
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
}
if (-not $success) {
    $evidence.failure = $failureMessage
}
Write-Evidence -Evidence $evidence

if (-not $success) {
    throw $failureMessage
}
Write-Output "[PASS] Isolated backup/restore drill evidence written outside repository: $OutputFullPath"

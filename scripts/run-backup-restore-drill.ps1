[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [Parameter(Mandatory = $true)][string]$PrivacyReplayManifestPath,
    [int]$TargetPort = 55432,
    [switch]$InitializeFoundation
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repositoryPrefix = $repositoryRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$composeFullPath = (Resolve-Path -LiteralPath (Join-Path (Join-Path $repositoryRoot "deploy") "compose.yaml")).Path
$sourceProject = "nutrition-p2-105-$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
$targetName = "nutrition-recovery-$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
$targetBackupName = "nutrition-recovery.dump"
$sourceStarted = $false
$targetStarted = $false
$apiProcess = $null
$encryptionKey = $null
$rawBackupPath = $null
$rawRestorePath = $null
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

    return Invoke-Docker -Arguments (@("compose", "--project-name", $sourceProject, "-f", $composeFullPath) + $Arguments) -Label $Label
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

function Protect-BackupArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $aes = [Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode = [Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
    $aes.GenerateKey()
    $aes.GenerateIV()
    $key = $aes.Key
    $magic = [Text.Encoding]::UTF8.GetBytes("nutrition-backup-encrypted-0.1.0`n")
    $plain = [IO.File]::ReadAllBytes($InputPath)
    $stream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($magic, 0, $magic.Length)
        $stream.Write($aes.IV, 0, $aes.IV.Length)
        $crypto = [Security.Cryptography.CryptoStream]::new(
            $stream,
            $aes.CreateEncryptor(),
            [Security.Cryptography.CryptoStreamMode]::Write
        )
        try {
            $crypto.Write($plain, 0, $plain.Length)
            $crypto.FlushFinalBlock()
        }
        finally {
            $crypto.Dispose()
        }
    }
    finally {
        $stream.Dispose()
        $aes.Dispose()
    }
    return ,$key
}

function Unprotect-BackupArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][byte[]]$Key
    )

    $encrypted = [IO.File]::ReadAllBytes($InputPath)
    $magic = [Text.Encoding]::UTF8.GetBytes("nutrition-backup-encrypted-0.1.0`n")
    $ivLength = 16
    if ($encrypted.Length -le ($magic.Length + $ivLength)) {
        throw "encrypted backup artifact is truncated"
    }
    for ($index = 0; $index -lt $magic.Length; $index++) {
        if ($encrypted[$index] -ne $magic[$index]) {
            throw "backup artifact encryption envelope is invalid"
        }
    }
    $iv = New-Object byte[] $ivLength
    [Array]::Copy($encrypted, $magic.Length, $iv, 0, $ivLength)
    $cipherLength = $encrypted.Length - $magic.Length - $ivLength
    $cipher = New-Object byte[] $cipherLength
    [Array]::Copy($encrypted, $magic.Length + $ivLength, $cipher, 0, $cipherLength)

    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $Key
    $aes.IV = $iv
    $aes.Mode = [Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
    $stream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $crypto = [Security.Cryptography.CryptoStream]::new(
            $stream,
            $aes.CreateDecryptor(),
            [Security.Cryptography.CryptoStreamMode]::Write
        )
        try {
            $crypto.Write($cipher, 0, $cipher.Length)
            $crypto.FlushFinalBlock()
        }
        finally {
            $crypto.Dispose()
        }
    }
    finally {
        $stream.Dispose()
        $aes.Dispose()
    }
}

function Get-PrivacyReplayManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Assert-ExternalPath -Path $Path -Label "PrivacyReplayManifestPath"
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "privacy replay manifest does not exist outside the repository"
    }
    $raw = Get-Content -Raw -LiteralPath $fullPath
    try {
        $manifest = $raw | ConvertFrom-Json
    }
    catch {
        throw "privacy replay manifest is not valid JSON"
    }
    $required = @(
        "schema_version",
        "environment",
        "replay_status",
        "production_authorization",
        "deleted_user_tombstones",
        "retention_tombstones"
    )
    foreach ($name in $required) {
        if ($null -eq $manifest.PSObject.Properties[$name]) {
            throw "privacy replay manifest is missing '$name'"
        }
    }
    $allowed = @($required | Sort-Object)
    $actual = @($manifest.PSObject.Properties.Name | Sort-Object)
    if ((ConvertTo-Json $actual -Compress) -ne (ConvertTo-Json $allowed -Compress)) {
        throw "privacy replay manifest contains unknown fields"
    }
    if ([string]$manifest.schema_version -ne "privacy-restore-gate-0.1.0" -or
        [string]$manifest.environment -ne "synthetic-local" -or
        [string]$manifest.replay_status -ne "applied" -or
        [bool]$manifest.production_authorization) {
        throw "privacy replay manifest is not an approved synthetic-local applied gate"
    }
    foreach ($name in @("deleted_user_tombstones", "retention_tombstones")) {
        if ([int64]$manifest.$name -lt 0) {
            throw "privacy replay manifest count '$name' is negative"
        }
    }
    return $manifest
}

function Get-DatabaseSnapshot {
    param([Parameter(Mandatory = $true)][string]$Container)

    $query = @"
WITH schema_objects AS (
    SELECT schemaname || '.' || tablename AS object_id
      FROM pg_catalog.pg_tables
     WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
), constraint_objects AS (
    SELECT namespace.nspname || '.' || relation.relname || ':' || constraint_item.conname || ':' ||
           pg_get_constraintdef(constraint_item.oid) AS object_id
      FROM pg_catalog.pg_constraint constraint_item
      JOIN pg_catalog.pg_class relation ON relation.oid = constraint_item.conrelid
      JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
     WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema')
), data_fingerprint AS (
    SELECT md5(concat(
        COALESCE((SELECT string_agg(
            id::text || ':' || COALESCE(user_id::text, '') || ':' || status || ':' || locale || ':' || created_at::text,
            '|' ORDER BY id
        ) FROM analysis.meal_analysis), ''), '|',
        COALESCE((SELECT string_agg(
            id::text || ':' || version || ':' || status || ':' || checksum_sha256,
            '|' ORDER BY id
        ) FROM catalog.catalog_release), ''), '|',
        COALESCE((SELECT string_agg(
            id::text || ':' || status || ':' || attempts::text,
            '|' ORDER BY id
        ) FROM ops.job), ''), '|',
        COALESCE((SELECT string_agg(
            id::text || ':' || event_type || ':' || COALESCE(published_at::text, ''),
            '|' ORDER BY id
        ) FROM ops.outbox_event), '')
    )) AS value
)
SELECT json_build_object(
    'migration_count', (SELECT count(*) FROM _sqlx_migrations),
    'migration_inventory', COALESCE((
        SELECT json_agg(json_build_object(
            'version', version,
            'description', description,
            'checksum', encode(checksum, 'hex'),
            'success', success
        ) ORDER BY version)
        FROM _sqlx_migrations
    ), '[]'::json),
    'schema_fingerprint', (SELECT md5(COALESCE(string_agg(object_id, E'\n' ORDER BY object_id), '')) FROM schema_objects),
    'constraint_fingerprint', (SELECT md5(COALESCE(string_agg(object_id, E'\n' ORDER BY object_id), '')) FROM constraint_objects),
    'data_fingerprint', (SELECT value FROM data_fingerprint),
    'analysis_count', (SELECT count(*) FROM analysis.meal_analysis),
    'catalog_release_count', (SELECT count(*) FROM catalog.catalog_release),
    'active_catalog_release_count', (SELECT count(*) FROM catalog.catalog_release WHERE status = 'active'),
    'raw_text_ciphertext_rows', (SELECT count(*) FROM analysis.meal_analysis WHERE raw_text_ciphertext IS NOT NULL),
    'privacy_deletion_event_count', (SELECT count(*) FROM ops.audit_event WHERE action = 'privacy.deletion_completed'),
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
        "privacy_deletion_event_count",
        "audit_event_count",
        "job_count",
        "outbox_event_count"
        )) {
        if ([int64]$Expected.$property -ne [int64]$Actual.$property) {
            throw "restore invariant mismatch for $property"
        }
    }
    if ([string]$Expected.schema_fingerprint -ne [string]$Actual.schema_fingerprint -or
        [string]$Expected.constraint_fingerprint -ne [string]$Actual.constraint_fingerprint -or
        [string]$Expected.data_fingerprint -ne [string]$Actual.data_fingerprint -or
        (ConvertTo-Json $Expected.migration_inventory -Depth 10 -Compress) -ne
        (ConvertTo-Json $Actual.migration_inventory -Depth 10 -Compress)) {
        throw "restore invariant fingerprint mismatch"
    }
    if ([int64]$Actual.raw_text_ciphertext_rows -ne 0) {
        throw "restored database contains raw meal text ciphertext rows"
    }
}

function Get-OwnerProbe {
    param([Parameter(Mandatory = $true)][string]$Container)

    $query = @"
SELECT json_build_object(
    'user_id', user_id::text,
    'analysis_count', count(*)
)
FROM analysis.meal_analysis
WHERE user_id IS NOT NULL
GROUP BY user_id
ORDER BY user_id
LIMIT 1;
"@
    return Invoke-DbJson -Container $Container -Query $query
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
    $binaryPath = Join-Path (Join-Path $repositoryRoot "target") (Join-Path "debug" $binaryName)
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
$PrivacyReplayManifestFullPath = Assert-ExternalPath -Path $PrivacyReplayManifestPath -Label "PrivacyReplayManifestPath"
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
$rollbackPlanPath = Join-Path (Join-Path $repositoryRoot "deploy") (Join-Path "recovery" "rollback-plan.json")
$rollbackPlanSha256 = $null
$privacyReplayManifest = $null

try {
    if (-not (Test-Path -LiteralPath $rollbackPlanPath -PathType Leaf)) {
        throw "rollback plan is missing: deploy/recovery/rollback-plan.json"
    }
    $rollbackPlanSha256 = (Get-FileHash -LiteralPath $rollbackPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()

    if (Test-Path -LiteralPath $BackupFullPath -PathType Leaf) {
        throw "BackupPath already exists; choose a new external path instead of overwriting an artifact"
    }
    Invoke-Compose -Arguments @("up", "-d", "--wait", "postgres") -Label "start disposable local source PostgreSQL" | Out-Null
    $sourceStarted = $true
    $sourceContainer = Get-SourceContainer
    Invoke-Docker -Arguments @("exec", $sourceContainer, "pg_isready", "-U", "nutrition", "-d", "nutrition") -Label "check source PostgreSQL" | Out-Null
    $sourceImage = ((Invoke-Docker -Arguments @("inspect", "--format", "{{.Config.Image}}", $sourceContainer) -Label "inspect source image") -join "`n").Trim()
    if ($sourceImage -ne "postgres:18") {
        throw "source container image is not the pinned local postgres:18 image"
    }
    $sourceComposeProject = ((Invoke-Docker -Arguments @("inspect", "--format", '{{index .Config.Labels "com.docker.compose.project"}}', $sourceContainer) -Label "inspect source compose project") -join "`n").Trim()
    if ($sourceComposeProject -ne $sourceProject) {
        throw "source container is not owned by this disposable recovery compose project"
    }

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
    $privacyReplayManifest = Get-PrivacyReplayManifest -Path $PrivacyReplayManifestFullPath
    if ([int64]$privacyReplayManifest.deleted_user_tombstones -ne [int64]$sourceSnapshot.privacy_deletion_event_count) {
        throw "privacy replay manifest does not cover the source deletion event count"
    }
    if ([int64]$privacyReplayManifest.retention_tombstones -ne 0) {
        throw "synthetic local foundation has no supported retention tombstone replay implementation"
    }

    $backupDirectory = Split-Path -Parent $BackupFullPath
    if (-not (Test-Path -LiteralPath $backupDirectory)) {
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    }
    $backupTimer = [Diagnostics.Stopwatch]::StartNew()
    $rawBackupPath = Join-Path $backupDirectory "$targetName.plain.dump"
    Invoke-Docker -Arguments @("exec", $sourceContainer, "rm", "-f", "/tmp/$targetBackupName") -Label "clear source backup scratch path" | Out-Null
    Invoke-Docker -Arguments @(
        "exec", $sourceContainer, "pg_dump", "-U", "nutrition", "-d", "nutrition", "-Fc", "-f", "/tmp/$targetBackupName"
    ) -Label "create local PostgreSQL backup" | Out-Null
    Invoke-Docker -Arguments @(
        "cp", ("{0}:/tmp/{1}" -f $sourceContainer, $targetBackupName), $rawBackupPath
    ) -Label "copy backup artifact outside repository" | Out-Null
    Protect-BackupArtifact -InputPath $rawBackupPath -OutputPath $BackupFullPath | ForEach-Object { $encryptionKey = $_ }
    Remove-Item -LiteralPath $rawBackupPath -Force
    Invoke-Docker -Arguments @("exec", $sourceContainer, "rm", "-f", "/tmp/$targetBackupName") -Label "remove source backup scratch artifact" | Out-Null
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
        "postgres:18"
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

    $rawRestorePath = Join-Path (Split-Path -Parent $BackupFullPath) "$targetName.restore.plain.dump"
    Unprotect-BackupArtifact -InputPath $BackupFullPath -OutputPath $rawRestorePath -Key $encryptionKey
    Invoke-Docker -Arguments @("cp", $rawRestorePath, ("{0}:/tmp/{1}" -f $targetName, $targetBackupName)) -Label "copy decrypted backup into isolated restore" | Out-Null
    Remove-Item -LiteralPath $rawRestorePath -Force
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
    $applicationChecks["migration_inventory_unchanged"] = ([string]$sourceSnapshot.schema_fingerprint -eq [string]$restoredSnapshot.schema_fingerprint)
    $applicationChecks["privacy_replay_gate"] = "verified-before-api"

    $apiPort = $TargetPort + 1000
    $metricsPort = $TargetPort + 2000
    $apiProcess = Start-RestoredApi -Port $apiPort -MetricsPort $metricsPort
    try {
        $baseUrl = "http://127.0.0.1:$apiPort"
        $readiness = Wait-ApiReady -BaseUrl $baseUrl
        if ($readiness.status -ne "ready") {
            throw "restored API readiness response was not ready"
        }
        $applicationChecks["api_readiness"] = "passed"
        $ownerId = "0198f100-0000-0000-8000-000000000098"
        $createBody = @{ text = "2 quả trứng gà luộc"; locale = "vi-VN"; mode = "balanced" } | ConvertTo-Json
        $createResponse = Invoke-WebRequest `
            -Method Post `
            -Uri "$baseUrl/v1/nutrition/analyses" `
            -Headers @{ Authorization = "Bearer dev:$ownerId"; "Idempotency-Key" = "recovery-$targetName" } `
            -ContentType "application/json; charset=utf-8" `
            -Body ([Text.Encoding]::UTF8.GetBytes($createBody)) `
            -TimeoutSec 5
        if ([int]$createResponse.StatusCode -ne 200) {
            throw "restored API synthetic create did not return HTTP 200"
        }
        $applicationChecks["restored_api_create"] = "passed"
        $ownerDatabaseCount = [int64](Invoke-DbScalar -Container $targetName -Query "SELECT count(*) FROM analysis.meal_analysis WHERE user_id = '$ownerId'::uuid;" -Label "check restored owner analysis count")
        $listResponse = Invoke-WebRequest -Uri "$baseUrl/v1/nutrition/analyses?page_size=50" -Headers @{ Authorization = "Bearer dev:$ownerId" } -TimeoutSec 5
        if ([int]$listResponse.StatusCode -ne 200) {
            throw "owner-scoped analysis listing did not return HTTP 200"
        }
        $list = $listResponse.Content | ConvertFrom-Json
        $listItems = @($list.items)
        if ($ownerDatabaseCount -ne 1 -or $listItems.Count -ne 1) {
            throw "owner-scoped analysis listing returned an unexpected item count (database=$ownerDatabaseCount, api=$($listItems.Count))"
        }
        $allowedListFields = @(
            "analysis_id",
            "status",
            "locale",
            "created_at",
            "current_revision_number",
            "result_status",
            "quality_label"
        )
        foreach ($item in $listItems) {
            $actualFields = @($item.PSObject.Properties.Name | Sort-Object)
            $expectedFields = @($allowedListFields | Sort-Object)
            if ((ConvertTo-Json $actualFields -Compress) -ne (ConvertTo-Json $expectedFields -Compress)) {
                throw "owner-scoped analysis listing exposed an unexpected field"
            }
        }
        $applicationChecks["owner_scoped_analysis_read"] = "passed"
        $foreignId = if ($ownerId -eq "0198f100-0000-7000-8000-000000000097") {
            "0198f100-0000-7000-8000-000000000096"
        }
        else {
            "0198f100-0000-7000-8000-000000000097"
        }
        $foreignResponse = Invoke-WebRequest -Uri "$baseUrl/v1/nutrition/analyses?page_size=50" -Headers @{ Authorization = "Bearer dev:$foreignId" } -TimeoutSec 5
        $foreignList = $foreignResponse.Content | ConvertFrom-Json
        if ([int]$foreignResponse.StatusCode -ne 200 -or @($foreignList.items).Count -ne 0) {
            throw "foreign owner analysis listing was not empty"
        }
        $applicationChecks["foreign_owner_isolation"] = "passed"
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
    foreach ($temporaryPath in @($rawBackupPath, $rawRestorePath)) {
        if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($sourceStarted) {
        try {
            if ($sourceContainer) {
                Invoke-Docker -Arguments @("exec", $sourceContainer, "rm", "-f", "/tmp/$targetBackupName") -Label "remove source scratch artifact" | Out-Null
            }
            Invoke-Compose -Arguments @("down", "-v", "--remove-orphans") -Label "remove disposable local source PostgreSQL" | Out-Null
        }
        catch {
            if ($null -eq $failureMessage) {
                $failureMessage = $_.Exception.Message
            }
            $success = $false
        }
    }
    $encryptionKey = $null
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
        host_class = "ephemeral-local-compose"
        project = $sourceProject
        image = "postgres:18"
    }
    backup = [ordered]@{
        format = "postgresql-custom-encrypted-aes-256-cbc"
        bytes = $backupBytes
        sha256 = $backupSha256
        duration_seconds = $backupDurationSeconds
        artifact_path_external_to_repository = $true
        encrypted_at_rest_for_local_drill = $true
        encryption_key_emitted = $false
    }
    restore = [ordered]@{
        isolated_container = $true
        postgres_image = "postgres:18"
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
        encryption = "OWNER-BE-005 requires platform encryption; local artifact used ephemeral AES-256-CBC and emitted no key"
        restore_tombstones_before_serve = if ($success) { "verified-by-external-manifest-before-api" } else { $false }
        privacy_replay_manifest_sha256 = if ($privacyReplayManifest) { (Get-FileHash -LiteralPath $PrivacyReplayManifestFullPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
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

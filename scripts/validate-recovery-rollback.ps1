[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repositoryPrefix = $repositoryRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar

function Assert-ExternalPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be outside the repository"
    }
    return $fullPath
}

function Assert-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Label)
    if ($Value -notmatch '^sha256:[0-9a-fA-F]{64}$') {
        throw "$Label must be a full sha256 digest"
    }
}

$inputFullPath = Assert-ExternalPath -Path $InputPath -Label "InputPath"
$outputFullPath = Assert-ExternalPath -Path $OutputPath -Label "OutputPath"
if (-not (Test-Path -LiteralPath $inputFullPath -PathType Leaf)) {
    throw "rollback evidence input does not exist"
}

$raw = Get-Content -Raw -LiteralPath $inputFullPath
try {
    $input = $raw | ConvertFrom-Json
}
catch {
    throw "rollback evidence input is not valid JSON"
}

$required = @(
    "schema_version",
    "environment",
    "production_authorization",
    "current_application_digest",
    "previous_application_digest",
    "current_config_fingerprint",
    "previous_config_fingerprint",
    "migration_compatibility",
    "catalog_rollback_validation",
    "catalog_source_status",
    "catalog_activation_performed"
)
foreach ($name in $required) {
    if ($null -eq $input.PSObject.Properties[$name]) {
        throw "rollback evidence input is missing '$name'"
    }
}
$allowed = @($required | Sort-Object)
$actual = @($input.PSObject.Properties.Name | Sort-Object)
if ((ConvertTo-Json $actual -Compress) -ne (ConvertTo-Json $allowed -Compress)) {
    throw "rollback evidence input contains unknown fields"
}
if ([string]$input.schema_version -ne "recovery-rollback-evidence-0.1.0" -or
    [string]$input.environment -ne "synthetic-local" -or
    [bool]$input.production_authorization -or
    [bool]$input.catalog_activation_performed) {
    throw "rollback evidence input is not a non-production synthetic validation"
}
foreach ($name in @(
        "current_application_digest",
        "previous_application_digest",
        "current_config_fingerprint",
        "previous_config_fingerprint"
    )) {
    Assert-Sha256 -Value ([string]$input.$name) -Label $name
}
if ([string]$input.migration_compatibility -ne "verified-forward-only" -or
    [string]$input.catalog_rollback_validation -ne "verified-staged-immutable-snapshot" -or
    [string]$input.catalog_source_status -ne "superseded") {
    throw "rollback evidence input does not satisfy forward-only/catalog rollback gates"
}

$evidence = [ordered]@{
    schema_version = "recovery-rollback-validation-0.1.0"
    status = "passed"
    evidence_kind = "synthetic-local-rollback-validation"
    owner_decision = "OWNER-BE-005"
    production_authorization = $false
    deployment_performed = $false
    catalog_activation_performed = $false
    application = [ordered]@{
        current_application_digest = [string]$input.current_application_digest
        previous_application_digest = [string]$input.previous_application_digest
        current_config_fingerprint = [string]$input.current_config_fingerprint
        previous_config_fingerprint = [string]$input.previous_config_fingerprint
        immutable_target_required = $true
    }
    migrations = [ordered]@{
        compatibility = "verified-forward-only"
        applied_migrations_mutated = $false
    }
    catalog = [ordered]@{
        source_status = "superseded"
        validation = "verified-staged-immutable-snapshot"
        activation_performed = $false
    }
    decision_boundary = "This validates the rollback evidence shape and gates only; it does not deploy, activate, change traffic, or authorize production."
    input_sha256 = (Get-FileHash -LiteralPath $inputFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
}
$parent = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
$evidence | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $outputFullPath -Encoding utf8
Write-Output "[PASS] Rollback validation evidence written outside repository: $OutputPath"

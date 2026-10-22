[CmdletBinding()]
param(
  [switch]$BuildApk,
  [switch]$VerifyCloud,
  [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'
$mobileRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $mobileRoot
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
  $ConfigFile = Join-Path $mobileRoot 'config/supabase.cloud.json'
}
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { throw 'Cloud build configuration is missing.' }
$config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
if ($config.PHONE_VERIFICATION_ENABLED -ne $true) { throw 'Hosted customer account builds require PHONE_VERIFICATION_ENABLED=true and a configured OTP delivery service.' }
if ($config.APP_ENV -notin @('staging','prod')) { throw 'Choose staging or prod explicitly for the hosted account workflow.' }
$url = [Uri]$config.SUPABASE_URL
if ($url.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($config.SUPABASE_ANON_KEY)) {
  throw 'HTTPS Supabase URL and public application key are required.'
}
if ($config.SUPABASE_ANON_KEY -like 'sb_secret_*') { throw 'A server secret cannot be included in the application.' }
if ($config.SUPABASE_ANON_KEY.Split('.').Count -eq 3) {
  $part = $config.SUPABASE_ANON_KEY.Split('.')[1].Replace('-', '+').Replace('_', '/')
  $part = $part.PadRight([int]([Math]::Ceiling($part.Length / 4.0) * 4), '=')
  $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
  if ($claims.role -eq 'service_role') { throw 'A service-role key cannot be included in the application.' }
}

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program failed (exit $LASTEXITCODE)." }
}

Push-Location $mobileRoot
try {
  Invoke-Checked 'flutter' @('pub', 'get')
  Invoke-Checked 'flutter' @('analyze', '--no-fatal-infos',
    'lib/core/database/app_database.dart', 'lib/core/sync/sync_engine.dart',
    'lib/features/merchant', 'lib/features/sync', 'lib/features/customer')
  # Keep Flutter test/build commands sequential on Windows (native SQLite DLL).
  Invoke-Checked 'flutter' @('test', '--no-test-assets',
    'test/customer_link_refresh_test.dart', 'test/customer_phone_link_session_test.dart',
    'test/customer_read_snapshot_test.dart', 'test/customer_controller_test.dart',
    'test/customer_phone_contract_test.dart', 'test/customer_phone_sync_test.dart',
    'test/customer_dependency_failure_test.dart', 'test/customer_directory_batch_test.dart',
    'test/customer_directory_controller_test.dart', 'test/customer_offline_snapshot_test.dart',
    'test/sync_pull_failure_test.dart', 'test/offline_sync_acceptance_test.dart',
    'test/money_accounting_test.dart')
  if ($VerifyCloud) {
    Push-Location (Join-Path $workspaceRoot 'debt-ledger-supabase')
    try {
      Invoke-Checked 'supabase' @('migration', 'list', '--linked')
      Invoke-Checked 'supabase' @('db', 'query', '--linked', '--file', 'tools/verify-account-contract.sql')
    } finally { Pop-Location }
  }
  if ($BuildApk) {
    Invoke-Checked 'flutter' @('build', 'apk', '--debug', "--dart-define-from-file=$ConfigFile")
    Write-Host ('Test APK: ' + (Join-Path $mobileRoot 'build/app/outputs/flutter-apk/app-debug.apk'))
  }
  Write-Host 'Selected local account workflow checks passed. Cloud deployment is a separate step.'
} finally { Pop-Location }

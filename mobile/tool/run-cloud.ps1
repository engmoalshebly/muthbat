[CmdletBinding()]
param(
  [string]$DeviceId,
  [ValidateSet('Release', 'Debug', 'Profile')]
  [string]$Mode = 'Release'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$configFile = Join-Path $projectRoot 'config/supabase.cloud.json'
$flutterArguments = @('run', "--$($Mode.ToLowerInvariant())", "--dart-define-from-file=$configFile")
if (-not [string]::IsNullOrWhiteSpace($DeviceId)) {
  $flutterArguments += @('--device-id', $DeviceId)
}

Push-Location $projectRoot
$previousJavaOptions = $env:JAVA_TOOL_OPTIONS
try {
  if (-not (Test-Path -LiteralPath $configFile)) {
    throw "Cloud configuration not found: $configFile"
  }
  if ($Mode -ne 'Debug') {
    # Keep dev-only plugins out of release/profile native registration.
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency preparation failed.' }
    & dart tool/prepare_release_plugin_registrant.dart
    if ($LASTEXITCODE -ne 0) { throw 'Native plugin preparation failed.' }
    $flutterArguments += '--no-pub'
    $javaSocketFolder = Join-Path (Split-Path -Parent $projectRoot) '.java-unix-socket'
    New-Item -ItemType Directory -Path $javaSocketFolder -Force | Out-Null
    $env:JAVA_TOOL_OPTIONS = "$previousJavaOptions -Djdk.net.unixdomain.tmpdir=$javaSocketFolder".Trim()
  }
  Write-Host "Running cloud app in $Mode mode. Existing app data will not be removed."
  & flutter @flutterArguments
  if ($LASTEXITCODE -ne 0) {
    throw 'Flutter cloud run failed. If Android reports a signature mismatch, use the matching signing key; do not uninstall an app containing unsynced data. Debug and release use different keys.'
  }
} finally {
  $env:JAVA_TOOL_OPTIONS = $previousJavaOptions
  Pop-Location
}

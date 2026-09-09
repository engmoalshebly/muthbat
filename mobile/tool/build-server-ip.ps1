[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:SUPABASE_ANON_KEY)) {
  throw 'Set SUPABASE_ANON_KEY to the server public anon key before building.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$socketTemp = Join-Path (Split-Path -Parent $projectRoot) '.java-unix-socket'
New-Item -ItemType Directory -Path $socketTemp -Force | Out-Null
$env:JAVA_TOOL_OPTIONS = "-Djdk.net.unixdomain.tmpdir=$socketTemp"
Write-Warning 'HTTP is unencrypted. APP_ENV=prod does not make this build safe for real credentials. Release currently uses the development signing key.'
Push-Location $projectRoot
try {
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
  & flutter build apk --release --no-pub `
    '--dart-define=SUPABASE_URL=http://217.216.79.195:55321' `
    "--dart-define=SUPABASE_ANON_KEY=$env:SUPABASE_ANON_KEY" `
    '--dart-define=APP_ENV=prod'
  if ($LASTEXITCODE -ne 0) { throw 'APK build failed.' }
  Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-release.apk' -Destination 'build/app/outputs/flutter-apk/muthbat-server-ip.apk'
} finally { Pop-Location }

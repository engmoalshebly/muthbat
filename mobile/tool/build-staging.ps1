[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:SUPABASE_ANON_KEY)) {
  throw 'SUPABASE_ANON_KEY must be provided as an environment variable.'
}
if ([string]::IsNullOrWhiteSpace($env:SUPABASE_URL)) {
  throw 'SUPABASE_URL must be provided as an environment variable.'
}
if ($env:SUPABASE_URL -notmatch '^https://[a-z0-9]+\.supabase\.co/?$') {
  throw 'SUPABASE_URL must be a hosted Supabase project URL.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$socketTemp = Join-Path (Split-Path -Parent $projectRoot) '.java-unix-socket'
New-Item -ItemType Directory -Path $socketTemp -Force | Out-Null

# Windows Java may prefer an AF_UNIX temporary socket that is rejected by
# endpoint protection in the default per-user Temp directory.  Keeping the
# Gradle socket under the workspace avoids changing global Windows settings.
$env:JAVA_TOOL_OPTIONS = "-Djdk.net.unixdomain.tmpdir=$socketTemp"

Set-Location $projectRoot
& flutter build apk --release --no-pub `
  "--dart-define=SUPABASE_URL=$($env:SUPABASE_URL.TrimEnd('/'))" `
  "--dart-define=SUPABASE_ANON_KEY=$env:SUPABASE_ANON_KEY" `
  '--dart-define=APP_ENV=staging'

exit $LASTEXITCODE

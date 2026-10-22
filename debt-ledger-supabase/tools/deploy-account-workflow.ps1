[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[a-z0-9]{20}$')]
  [string]$ProjectRef,
  [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$backendRoot = Split-Path -Parent $PSScriptRoot
function Invoke-Checked([string[]]$Arguments) {
  & supabase @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Supabase failed (exit $LASTEXITCODE). Restore project access before continuing." }
}
Push-Location $backendRoot
try {
  Invoke-Checked @('link','--project-ref',$ProjectRef)
  Invoke-Checked @('migration','list','--linked')
  Invoke-Checked @('db','push','--include-all','--skip-vault','--dry-run')
  if ($CheckOnly) {
    Write-Host 'Deployment preflight completed. No remote migrations or functions changed.'
    return
  }
  Invoke-Checked @('db','push','--include-all','--skip-vault')
  Invoke-Checked @('db','query','--linked','--file','tools/verify-account-contract.sql')
  Invoke-Checked @('functions','deploy','customer-directory','customer-contacts','local-notebook-import','bootstrap-user-contact','verify-whatsapp-otp','--project-ref',$ProjectRef)
  Write-Host 'Account database contract and customer onboarding Edge Functions deployed. Build and test the app on a device next.'
} finally { Pop-Location }

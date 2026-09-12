#!/usr/bin/env bash
set -euo pipefail

if [[ "${CONFIRM_STAGING_BYPASS:-}" != 'ENABLE_TEMPORARILY' ]]; then
  echo 'Set CONFIRM_STAGING_BYPASS=ENABLE_TEMPORARILY to enable this emergency bypass.' >&2
  exit 2
fi
project_ref="${SUPABASE_PROJECT_REF:-}"
if [[ ! "$project_ref" =~ ^[a-z0-9]{20}$ ]]; then
  echo 'SUPABASE_PROJECT_REF must be the staging project reference.' >&2
  exit 2
fi

supabase secrets set APP_ENV=staging ALLOW_STAGING_DIRECT_AUTH=true --project-ref "$project_ref"
supabase functions deploy staging-direct-signup --project-ref "$project_ref"
echo 'WARNING: staging-direct-signup is enabled. Run disable-direct-signup.sh when finished.'

#!/usr/bin/env bash
set -euo pipefail

project_ref="${SUPABASE_PROJECT_REF:-}"
if [[ ! "$project_ref" =~ ^[a-z0-9]{20}$ ]]; then
  echo 'SUPABASE_PROJECT_REF must be the staging project reference.' >&2
  exit 2
fi

supabase secrets set APP_ENV=staging ALLOW_STAGING_DIRECT_AUTH=false --project-ref "$project_ref"
# A deployed copy remains fail-closed; deletion also removes the public route.
supabase functions delete staging-direct-signup --project-ref "$project_ref" --yes 2>/dev/null || true
echo 'staging-direct-signup is disabled and its hosted function was removed when present.'

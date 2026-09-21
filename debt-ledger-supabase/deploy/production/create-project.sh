#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_ORG_ID:?SUPABASE_ORG_ID is required}"
: "${SUPABASE_DB_PASSWORD:?SUPABASE_DB_PASSWORD is required and must never be committed}"

project_name="${SUPABASE_PROJECT_NAME:-muthbat-prod}"
region="${SUPABASE_REGION:-ap-south-1}"
size="${SUPABASE_SIZE:-}"

if [[ ! "$project_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{2,49}$ ]]; then
  echo 'SUPABASE_PROJECT_NAME contains invalid characters.' >&2
  exit 2
fi
if [[ ! "$region" =~ ^[a-z0-9-]+$ ]]; then
  echo 'SUPABASE_REGION is invalid.' >&2
  exit 2
fi

echo "Creating dedicated Supabase project '$project_name' in '$region'..."
create_args=("$project_name" "--org-id" "$SUPABASE_ORG_ID" "--db-password" "$SUPABASE_DB_PASSWORD" "--region" "$region" "--yes" "--output" "json")
if [[ -n "$size" ]]; then
  create_args+=("--size" "$size")
fi
supabase projects create "${create_args[@]}"

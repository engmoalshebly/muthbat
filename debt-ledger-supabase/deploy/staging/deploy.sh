#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backend_dir="$(cd "$script_dir/../.." && pwd)"
env_file="${STAGING_ENV_FILE:-$script_dir/.env}"
project_ref="${SUPABASE_PROJECT_REF:-}"

if [[ ! "$project_ref" =~ ^[a-z0-9]{20}$ ]]; then
  echo 'SUPABASE_PROJECT_REF must be the 20-character staging project reference.' >&2
  exit 2
fi
if [[ ! -f "$env_file" ]]; then
  echo "Missing staging secrets file: $env_file" >&2
  exit 2
fi

required=(APP_ENV ALLOW_STAGING_DIRECT_AUTH PHONE_HMAC_KEY PHONE_ENCRYPTION_KEY WORKER_SECRET OPENWA_BASE_URL OPENWA_SESSION_ID OPENWA_API_KEY)
for key in "${required[@]}"; do
  value="$(sed -n "s/^${key}=//p" "$env_file" | tail -n 1)"
  if [[ -z "$value" || "$value" == replace-* ]]; then
    echo "Missing or placeholder value for $key" >&2
    exit 2
  fi
done
if ! grep -qx 'APP_ENV=staging' "$env_file" || ! grep -qx 'ALLOW_STAGING_DIRECT_AUTH=false' "$env_file"; then
  echo 'Staging deploy requires APP_ENV=staging and ALLOW_STAGING_DIRECT_AUTH=false.' >&2
  exit 2
fi
openwa_url="$(sed -n 's/^OPENWA_BASE_URL=//p' "$env_file" | tail -n 1)"
if [[ ! "$openwa_url" =~ ^https:// ]]; then
  echo 'OPENWA_BASE_URL must use HTTPS for hosted staging.' >&2
  exit 2
fi

cd "$backend_dir"
supabase link --project-ref "$project_ref"
# Staging config is intentionally minimal so the diff cannot overwrite unrelated
# hosted settings inherited from the dashboard.
supabase --workdir "$script_dir" config diff --project-ref "$project_ref"
supabase --workdir "$script_dir" config push --project-ref "$project_ref" --yes
supabase db push --include-all
supabase secrets set --env-file "$env_file"

# Deliberately excludes staging-direct-signup. Use enable-direct-signup.sh for
# a short-lived, explicitly approved test and disable it immediately afterwards.
functions=(
  bootstrap-user-contact combine-statements customer-directory
  finalize-document-upload generate-statement member-invite
  process-automation-rules process-notification-outbox send-whatsapp-otp
  signed-document-upload verify-statement verify-whatsapp-otp
)
for function_name in "${functions[@]}"; do
  supabase functions deploy "$function_name" --project-ref "$project_ref"
done

echo 'Staging database, secrets, and standard Edge Functions deployed.'

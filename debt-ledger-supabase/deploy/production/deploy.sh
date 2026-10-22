#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backend_dir="$(cd "$script_dir/../.." && pwd)"
env_file="${PRODUCTION_ENV_FILE:-$script_dir/.env}"
project_ref="${SUPABASE_PROJECT_REF:-}"

if [[ ! "$project_ref" =~ ^[a-z0-9]{20}$ ]]; then
  echo 'SUPABASE_PROJECT_REF must be the 20-character production project reference.' >&2
  exit 2
fi
if [[ ! -f "$env_file" ]]; then
  echo "Missing production secrets file: $env_file" >&2
  exit 2
fi

required=(APP_ENV ALLOW_STAGING_DIRECT_AUTH WHATSAPP_OTP_ENABLED PHONE_HMAC_KEY PHONE_ENCRYPTION_KEY PHONE_KEY_VERSION WORKER_SECRET ALLOWED_ORIGIN OPENWA_BASE_URL OPENWA_SESSION_ID OPENWA_API_KEY)
for key in "${required[@]}"; do
  value="$(sed -n "s/^${key}=//p" "$env_file" | tail -n 1)"
  if [[ -z "$value" || "$value" == replace-* ]]; then
    echo "Missing or placeholder value for $key" >&2
    exit 2
  fi
done
if ! grep -qx 'APP_ENV=prod' "$env_file" || ! grep -qx 'ALLOW_STAGING_DIRECT_AUTH=false' "$env_file"; then
  echo 'Production deploy requires APP_ENV=prod and ALLOW_STAGING_DIRECT_AUTH=false.' >&2
  exit 2
fi
if ! grep -qx 'WHATSAPP_OTP_ENABLED=true' "$env_file" || ! grep -qx 'ALLOW_PHONE_PASSWORD_SIGNUP=false' "$env_file" || ! grep -qx 'ALLOW_STAGING_UNVERIFIED_PHONE_LINKS=false' "$env_file"; then
  echo 'Production requires WhatsApp OTP and disables unverified signup and phone linking.' >&2
  exit 2
fi
openwa_url="$(sed -n 's/^OPENWA_BASE_URL=//p' "$env_file" | tail -n 1)"
if [[ ! "$openwa_url" =~ ^https:// ]]; then
  echo 'OPENWA_BASE_URL must use HTTPS for production.' >&2
  exit 2
fi

cd "$backend_dir"
supabase link --project-ref "$project_ref"
# Preserve the existing hosted phone/password provider. Pushing a configuration
# with every native SMS provider disabled can turn phone sign-in off, even
# though WhatsApp verification is handled by our Edge Functions.
# Configure and verify hosted Auth separately before the production cutover.
supabase db push --include-all
supabase secrets set --env-file "$env_file"

functions=(
  phone-password-signup
  bootstrap-user-contact combine-statements customer-directory customer-contacts local-notebook-import
  finalize-document-upload generate-statement member-invite
  process-automation-rules process-notification-outbox send-whatsapp-otp
  signed-document-upload verify-statement verify-whatsapp-otp
)
for function_name in "${functions[@]}"; do
  supabase functions deploy "$function_name" --project-ref "$project_ref"
done

echo 'Production Supabase database, secrets, and Edge Functions deployed.'

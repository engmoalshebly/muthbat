#!/usr/bin/env bash
set -euo pipefail

required=(SUPABASE_URL SUPABASE_ANON_KEY OPENWA_BASE_URL OPENWA_API_KEY)
for key in "${required[@]}"; do
  [[ -n "${!key:-}" ]] || { echo "$key is required." >&2; exit 2; }
done

status_code() {
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$@"
}

health_status="$(status_code "$OPENWA_BASE_URL/api/health/ready")"
[[ "$health_status" == '200' ]] || { echo "OpenWA readiness failed: HTTP $health_status" >&2; exit 1; }

anonymous_status="$(status_code "$OPENWA_BASE_URL/api/sessions")"
[[ "$anonymous_status" == '401' ]] || { echo "OpenWA anonymous access expected 401, got $anonymous_status" >&2; exit 1; }

authorized_status="$(status_code -H "X-API-Key: $OPENWA_API_KEY" "$OPENWA_BASE_URL/api/sessions")"
[[ "$authorized_status" =~ ^2 ]] || { echo "OpenWA API key rejected: HTTP $authorized_status" >&2; exit 1; }

direct_status="$(status_code -X POST \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"phone":"+10000000000","password":"not-a-real-password","displayName":"Disabled Probe"}' \
  "$SUPABASE_URL/functions/v1/staging-direct-signup")"
if [[ "$direct_status" != '403' && "$direct_status" != '404' ]]; then
  echo "staging-direct-signup must be absent or disabled; got HTTP $direct_status" >&2
  exit 1
fi

rls_url="$SUPABASE_URL/rest/v1/businesses?select=id&limit=1"
rls_body="$(curl --silent --show-error -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY" "$rls_url")"
[[ "$rls_body" == '[]' ]] || { echo 'Anonymous user can read business rows.' >&2; exit 1; }

echo 'Access checks passed: OpenWA protected, direct signup disabled, anonymous Supabase rows hidden.'

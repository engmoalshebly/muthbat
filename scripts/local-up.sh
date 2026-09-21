#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT_DIR/.local"
SUPABASE_DIR="$ROOT_DIR/debt-ledger-supabase"
SUPABASE_ENV="$SUPABASE_DIR/supabase/.env"
OPENWA_DIR="$ROOT_DIR/OpenWA"
OPENWA_ENV="$OPENWA_DIR/.env"
INSURANCE_DIR="$ROOT_DIR/insurance-backend"
INSURANCE_ENV="$INSURANCE_DIR/.env"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_command docker
require_command supabase
require_command curl
require_command openssl

mkdir -p "$LOCAL_DIR"
umask 077

if [[ ! -f "$OPENWA_ENV" ]]; then
  cp "$OPENWA_DIR/.env.example" "$OPENWA_ENV"
  sed -i 's|^DATABASE_TYPE=.*|DATABASE_TYPE=postgres|' "$OPENWA_ENV"
  sed -i 's|^DATABASE_HOST=.*|DATABASE_HOST=postgres|' "$OPENWA_ENV"
  sed -i 's|^DATABASE_USERNAME=.*|DATABASE_USERNAME=openwa|' "$OPENWA_ENV"
  sed -i 's|^DATABASE_PASSWORD=.*|DATABASE_PASSWORD=openwa|' "$OPENWA_ENV"
  sed -i 's|^DATABASE_SYNCHRONIZE=.*|DATABASE_SYNCHRONIZE=false|' "$OPENWA_ENV"
fi
openwa_api_key="$(sed -n 's/^API_MASTER_KEY=//p' "$OPENWA_ENV" | tail -n 1)"
if [[ -z "$openwa_api_key" ]]; then
  openwa_api_key="$(openssl rand -hex 32)"
  sed -i "s|^API_MASTER_KEY=.*|API_MASTER_KEY=$openwa_api_key|" "$OPENWA_ENV"
fi

if [[ ! -f "$INSURANCE_ENV" ]]; then
  cp "$INSURANCE_DIR/.env.example" "$INSURANCE_ENV"
  insurance_password="$(openssl rand -hex 16)"
  sed -i 's|^TEST_API_USERNAME=.*|TEST_API_USERNAME=local-demo|' "$INSURANCE_ENV"
  sed -i "s|^TEST_API_PASSWORD=.*|TEST_API_PASSWORD=$insurance_password|" "$INSURANCE_ENV"
fi

if [[ ! -f "$SUPABASE_ENV" ]]; then
  cp "$SUPABASE_DIR/supabase/.env.example" "$SUPABASE_ENV"
  sed -i "s|^PHONE_HMAC_KEY=.*|PHONE_HMAC_KEY=$(openssl rand -base64 32)|" "$SUPABASE_ENV"
  sed -i "s|^PHONE_ENCRYPTION_KEY=.*|PHONE_ENCRYPTION_KEY=$(openssl rand -base64 32)|" "$SUPABASE_ENV"
  sed -i "s|^WORKER_SECRET=.*|WORKER_SECRET=$(openssl rand -hex 32)|" "$SUPABASE_ENV"
fi

echo "Starting local Supabase..."
(
  cd "$SUPABASE_DIR"
  if ! supabase start --yes >"$LOCAL_DIR/supabase-start.log" 2>&1; then
    cat "$LOCAL_DIR/supabase-start.log" >&2
    exit 1
  fi
)

echo "Starting OpenWA API, dashboard, and local dependencies..."
(
  cd "$OPENWA_DIR"
  docker compose --profile postgres --profile with-dashboard --profile with-proxy up -d --build
)

echo "Starting isolated insurance demo..."
(
  cd "$INSURANCE_DIR"
  INSURANCE_ENV=demo \
    DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1 \
    PUBLIC_BASE_URL=http://localhost:8000 \
    ENABLE_TEST_PAYMENTS=true \
    docker compose --profile demo up -d --build
)

echo "Starting local Supabase Edge Functions..."
(
  cd "$SUPABASE_DIR"
  eval "$(supabase status -o env 2>/dev/null)"
  export SUPABASE_URL="$API_URL"
  export SUPABASE_ANON_KEY="$ANON_KEY"
  export SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"
  export OPENWA_BASE_URL=http://127.0.0.1:2785
  export OPENWA_SESSION_ID=default
  export OPENWA_API_KEY="$openwa_api_key"
  if curl --silent --output /dev/null --write-out '%{http_code}' \
      -X POST http://127.0.0.1:55321/functions/v1/verify-statement \
      -H 'content-type: application/json' -d '{"code":"bad"}' | grep -q '^422$'; then
    echo "Edge Functions already running."
  else
    nohup supabase functions serve --no-verify-jwt \
      >"$LOCAL_DIR/supabase-functions.log" 2>&1 < /dev/null &
  fi
)

echo "Waiting for local endpoints..."
for attempt in $(seq 1 40); do
  if curl --silent --fail http://127.0.0.1:2785/api/health >/dev/null \
    && curl --silent --fail http://127.0.0.1:8000/api/v1/health >/dev/null \
    && curl --silent --output /dev/null --write-out '%{http_code}' \
      -X POST http://127.0.0.1:55321/functions/v1/verify-statement \
      -H 'content-type: application/json' -d '{"code":"bad"}' | grep -q '^422$'; then
    break
  fi
  if [[ "$attempt" == 40 ]]; then
    echo "Local services did not become ready." >&2
    echo "Edge log: $LOCAL_DIR/supabase-functions.log" >&2
    exit 1
  fi
  sleep 2
done

echo
echo "Local stack is ready."
echo "  Mobile Supabase: http://10.0.2.2:55321 (Android emulator)"
echo "  Supabase Studio: http://127.0.0.1:55323"
echo "  OpenWA API:      http://127.0.0.1:2785"
echo "  OpenWA dashboard: http://127.0.0.1:2886"
echo "  Insurance demo:  http://127.0.0.1:8000"
echo
echo "Run the mobile app with:"
echo "  cd mobile && flutter run --dart-define=APP_ENV=dev"

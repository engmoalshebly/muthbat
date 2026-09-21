#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT_DIR/.local"

if [[ -f "$LOCAL_DIR/supabase-functions.pid" ]]; then
  pid="$(<"$LOCAL_DIR/supabase-functions.pid")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$LOCAL_DIR/supabase-functions.pid"
fi

(
  cd "$ROOT_DIR/OpenWA"
  docker compose --profile postgres --profile with-dashboard --profile with-proxy down
)
(
  cd "$ROOT_DIR/insurance-backend"
  docker compose --profile demo down
)
(
  cd "$ROOT_DIR/debt-ledger-supabase"
  supabase stop --no-backup
)

echo "Local services stopped. Persistent Docker volumes were preserved."

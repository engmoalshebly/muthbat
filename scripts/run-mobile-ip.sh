#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{for (i = 1; i <= NF; i++) if ($i !~ /:/ && $i != "127.0.0.1") { print $i; exit }}')}"

if [[ -z "$SERVER_IP" ]]; then
  echo "Could not detect the server IPv4 address. Set SERVER_IP explicitly." >&2
  exit 1
fi
command -v flutter >/dev/null 2>&1 || { echo "Missing required command: flutter" >&2; exit 1; }
command -v supabase >/dev/null 2>&1 || { echo "Missing required command: supabase" >&2; exit 1; }

eval "$(cd "$ROOT_DIR/debt-ledger-supabase" && supabase status -o env 2>/dev/null)"
if [[ -z "${ANON_KEY:-}" ]]; then
  echo "Supabase is not running. Start it with ./scripts/local-up.sh first." >&2
  exit 1
fi

cd "$ROOT_DIR/mobile"
flutter run \
  --dart-define="SUPABASE_URL=http://${SERVER_IP}:55321" \
  --dart-define="SUPABASE_ANON_KEY=${ANON_KEY}" \
  --dart-define=APP_ENV=dev \
  "$@"

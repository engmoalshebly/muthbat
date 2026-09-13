# Staging validation — 2026-09-13

Project: `muthbat` (`ylzzascthljvomzclorl`). The owner chose to use this
single project as the current test environment; it must not be treated as an
independent production environment.

## Automated evidence

- All local migrations match remote migration history.
- Twelve operational Edge Functions are active.
- `staging-direct-signup` is absent (`HTTP 404`).
- Native Supabase phone signup is disabled (`HTTP 400`, unsupported provider).
- OpenWA is served through HTTPS and protected API endpoints reject anonymous
  requests (`HTTP 401`).
- OpenWA data storage is PostgreSQL; WhatsApp credentials use a persistent
  Docker volume.
- OTP request rate limiting returned `HTTP 429` during the cooldown window.
- A real OTP delivery request returned `HTTP 201`, challenge lifetime 300
  seconds.
- Wrong OTP `000000` returned `HTTP 400 invalid_otp`.
- After recreating the OpenWA container, the authenticated WhatsApp session
  resumed automatically and returned to `ready` without a new QR scan.

## Still requiring human evidence

- Confirm that the `HTTP 201` OTP message appeared on the destination WhatsApp
  device.
- Confirm an actually expired challenge is rejected after five minutes.
- Complete merchant/customer account creation on two devices and verify tenant
  isolation through the UI.

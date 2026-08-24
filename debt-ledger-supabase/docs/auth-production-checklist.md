# Authentication production checklist

## Runtime policy

- Account creation and password recovery go through `send-whatsapp-otp` and `verify-whatsapp-otp` only.
- Supabase public sign-up is disabled in `supabase/config.toml`.
- JWT expiry is 15 minutes; the Flutter client keeps the refresh session through Supabase Auth.
- The service-role key is runtime-injected and is never included in the Flutter app, Edge Function source, or repository.

## Required production secrets

Set these through the Supabase secret manager, never in source control:

- `SUPABASE_SERVICE_ROLE_KEY` (normally injected by Supabase)
- `OPENWA_BASE_URL`
- `OPENWA_SESSION_ID`
- `OPENWA_API_KEY`
- `PHONE_HMAC_KEY`
- `PHONE_ENCRYPTION_KEY`
- `ALLOWED_ORIGIN`

## Release gates

1. Apply migrations through `202608190021_auth_production_hardening.sql`.
2. Confirm `service_*whatsapp_otp` and `service_find_auth_user_by_phone` have no `anon` or `authenticated` execute grants.
3. Confirm direct email and phone sign-up are disabled in the hosted Supabase Auth settings as well as local `config.toml`.
4. Confirm OpenWA is reachable only from the Edge Function/service network and its API key is rotated per environment.
5. Run database pgTAP tests and Flutter tests.
6. Exercise the full flows: signup, wrong OTP five times, expired OTP, resend cooldown, recovery, old password rejection, new password login, and offline session restoration.


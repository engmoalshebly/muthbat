# Customer snapshot release record — 2026-10-19

The customer home screen now reads the summary, link requests, and pending entries from one server snapshot. The snapshot is read in deterministic pages, and an incomplete or failed page leaves the previously cached dataset intact. Statement export opens a fresh snapshot and loads the full ledger before creating the PDF. Customer outbox processing batches up to 50 actions per synchronization cycle, with a 20-second request budget and stable idempotency receipts.

Validation completed:
- 20 focused Flutter customer tests passed, including large paginated datasets and full-history PDF input.
- PostgreSQL migration test passed with 1,001 linked stores, link requests, and ledger rows; it verified snapshot stability across a concurrent write and access revocation after archival.
- Supabase account RPC contract query passed against the linked project.
- Deno tests and type checks passed for phone-contact bootstrap and OTP recovery.

Deployment completed on Supabase project `sgnbtrcbllnffcyzsjei` (the project configured as `staging` in `mobile/config/supabase.cloud.json`): migrations `20261019170923_merchant_onboarding_receipt.sql` and `20261019173758_customer_read_snapshots.sql` are applied. The five customer/contact and phone-auth Edge Functions are active. `customer-directory`, `customer-contacts`, and `local-notebook-import` were already current; `bootstrap-user-contact` and `verify-whatsapp-otp` were deployed in this release. The account RPC contract check passed after migration.

A staging debug APK was rebuilt at `mobile/build/app/outputs/flutter-apk/app-debug.apk` with phone verification enabled. SHA-256: `15A33549746C34D395B74F8A61734A6F4A6164F777F93A66CB671FA8BB1E99C7`.

This is a staging deployment, not a production store release. The project has no WhatsApp provider secrets (`OPENWA_BASE_URL`, `OPENWA_SESSION_ID`, `OPENWA_API_KEY`) in its Supabase secrets, so live OTP delivery still requires provider configuration and a device/phone acceptance test. Android release signing is also not configured (`mobile/android/key.properties` and a non-debug keystore are absent). No production Supabase project was configured, and no production database was changed.

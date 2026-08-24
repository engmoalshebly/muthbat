# Required Supabase Edge Functions

## 1. `bootstrap-user-contact`

After phone OTP login, reads the authenticated user's verified phone from Auth, normalizes it to E.164, computes HMAC-SHA256 for lookup, encrypts it with AES-256-GCM, and calls the service-only contact RPC. Secrets:

- `PHONE_HMAC_KEY`
- `PHONE_ENCRYPTION_KEY`
- `PHONE_KEY_VERSION`

## 2. `customer-directory`

Merchant-facing endpoint that:

1. verifies the caller JWT;
2. verifies membership in the requested business;
3. normalizes and HMACs the phone number;
4. calls `service_find_customer_by_phone_hash`;
5. creates an unregistered `customers` row when needed;
6. calls `add_business_customer` and optionally `request_customer_link`;
7. applies per-user and per-business rate limiting to prevent phone enumeration.

Do not return whether an arbitrary phone belongs to a registered person until the merchant has a legitimate customer-creation flow.

## 3. `signed-document-upload`

Validates business/customer access, validates MIME type and intended entity, generates a short-lived signed upload URL for `ledger-documents`, then finalizes metadata in `public.files`. The client receives no secret key.

## 4. `process-notification-outbox`

Claims rows using `service_claim_notification_batch`, loads active device tokens, sends FCM/APNs/Expo push notifications, then calls complete/fail RPCs. Run on a schedule with Supabase Cron + Edge Functions.

## 5. `generate-statement`

Authorizes the merchant/customer, creates an immutable snapshot in `statements` and `statement_items`, renders PDF, uploads it to the private `statements` bucket, stores SHA-256, and returns a signed URL.

## 6. `verify-statement`

Public rate-limited endpoint that accepts only the verification code and returns limited non-PII verification data: validity, generation date, period, currency, closing balance, and document hash. It must not expose customer identity or transaction lines.

## Secrets boundary

Use the client publishable key in Flutter/Web. Elevated secret/service-role credentials stay only in Edge Functions. Every service-role operation must first verify authorization or be a service-to-service worker.

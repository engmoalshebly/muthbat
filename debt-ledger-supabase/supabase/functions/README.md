# Supabase Edge Functions — Debt Ledger MVP

Production-ready Edge Functions implemented under Deno runtime with full TypeScript typing, CORS preflight handling, rate limiting, and least-privilege security:

1. **`bootstrap-user-contact`**
   - Normalizes verified user phone to E.164.
   - Computes HMAC-SHA256 hash for secure lookups.
   - Encrypts phone with AES-256-GCM.
   - Stores contact record in `private.customer_contacts`.

2. **`customer-directory`**
   - Merchant-facing secure directory lookup.
   - Prevents phone enumeration via rate limiting.
   - Creates unregistered customer records if absent.
   - Links customer to business via `add_business_customer` and optionally `request_customer_link`.

3. **`signed-document-upload`**
   - Creates temporary signed upload sessions for `ledger-documents`.
   - Validates MIME type and max size (10 MiB).

4. **`finalize-document-upload`**
   - Verifies SHA-256 digest and actual byte size.
   - Inserts file metadata into `public.files` and associates it with `ledger_entries` or `dispute_messages`.

5. **`generate-statement`**
   - Generates authoritative statement snapshots via `create_statement` RPC.
   - Renders structured multi-page PDF documents with financial summaries and transaction item tables using `pdf-lib`.
   - Uploads to private `statements` bucket and locks SHA-256 fingerprint in `public.statements`.
   - Returns temporary signed download URL.

6. **`verify-statement`**
   - Public rate-limited endpoint for instant statement validation.
   - Validates statement verification code (`ST-XXXX`), period, currency, closing balance, and SHA-256 document hash without leaking PII.

7. **`process-automation-rules`**
   - Background worker for evaluating due/overdue debt rules and dispute SLAs.
   - Business timezone-aware sending window enforcement.
   - Idempotent run execution with `automation_runs`.
   - Dispatches in-app notifications and reminder records.

8. **`process-notification-outbox`**
   - Background push worker claiming batches with `service_claim_notification_batch`.
   - Multi-provider dispatch: **Firebase Cloud Messaging (FCM)**, **Expo Push**, or in-app mock.
   - Records all attempts in `private.notification_delivery_attempts`.

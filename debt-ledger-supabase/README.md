# Supabase Debt Ledger MVP

Production-oriented database foundation for a trusted debt ledger with merchant tenancy, unified customer identity, notifications, confirmations, disputes, and verifiable statements.

## Product and application specification

The complete first-version product, mobile, offline-first, automation, database, security, and delivery reference is available in [docs/first-version-product-architecture-spec.md](docs/first-version-product-architecture-spec.md).

The implemented database catalogue, relationships, command lifecycle, RLS model, and verification record are in [docs/database-architecture-and-operations-spec.md](docs/database-architecture-and-operations-spec.md).

The applied double-entry accounting model (debit/credit, customer due/credit, discounts, journals, and trial balance) is in [docs/double-entry-accounting-spec.md](docs/double-entry-accounting-spec.md).

The complete client-facing API catalogue, request contracts, permissions, and operational sequences is in [docs/api-reference-and-operational-flow.md](docs/api-reference-and-operational-flow.md).

## Supabase components

- **PostgreSQL:** authoritative relational and financial data.
- **Supabase Auth:** phone OTP identity; one user may act as merchant and customer.
- **Row Level Security:** tenant and customer data isolation.
- **Database Functions/RPC:** atomic financial commands and permission checks.
- **Triggers:** invariants, event history, projections, notifications, and audit.
- **Storage:** private attachments/statements and public business assets.
- **Realtime:** notification and state updates only.
- **Edge Functions:** encrypted customer directory, signed uploads, push worker, PDF generation, verification.
- **Cron / pg_net:** scheduled request expiry and outbox processing.
- **pgTAP:** schema, command, invariant, and RLS tests.

## Migration order

1. `202607120001_core_schema.sql`
2. `202607120002_functions_and_triggers.sql`
3. `202607120003_rls_and_grants.sql`
4. `202607120004_storage_realtime.sql`
5. `202607120005_operations_audit.sql`
6. `202608140006_platform_hardening_and_offline.sql`
7. `202608140007_lint_and_link_command_fixes.sql`
8. `202608140008_member_invites_and_statement_commands.sql`
9. `202608140009_ledger_discount_enum.sql`
10. `202608140010_double_entry_accounting.sql`
11. `202608140011_accounting_command_receipts.sql`
12. `202608190013_multi_currency_redo.sql`
13. `202608190014_rpc_contract_extensions.sql`
14. `202608190015_financial_integrity.sql`
15. `202608190016_security_hardening.sql`
16. `202608190017_profiles_user_type.sql`
17. `202608190018_openwa_otp_challenges.sql`
18. `202608190019_public_whatsapp_otp_rpc.sql`
19. `202608190020_secure_whatsapp_otp_gateway.sql`
20. `202608190021_auth_production_hardening.sql`
21. `202608190022_currency_consistency.sql`
22. `202608190023_p1_precision_currency_accounts_reconciliation.sql`
23. `202608190024_currency_catalog_data_repair.sql`
24. `202608190025_customer_directory_service_grants.sql`
25. `202608190026_ledger_timeline_contract.sql`
26. `202608190027_direct_business_customer_command.sql`
27. `202608200001_prevent_duplicate_business_customer.sql`
12. `202608190013_multi_currency_redo.sql`
13. `202608190014_rpc_contract_extensions.sql`
14. `202608190015_financial_integrity.sql`
15. `202608190016_security_hardening.sql`
16. `202608190017_profiles_user_type.sql`
17. `202608190018_openwa_otp_challenges.sql`
18. `202608190019_public_whatsapp_otp_rpc.sql`
19. `202608190020_secure_whatsapp_otp_gateway.sql`
20. `202608190021_auth_production_hardening.sql`

## Local setup

```bash
npx supabase start --yes
npx supabase migration up --local
npx supabase db lint --local
npx supabase test db
```

### Local service endpoints

This project uses an isolated local port range to avoid collisions with other Supabase projects:

- API: `http://127.0.0.1:55321`
- PostgreSQL: `postgresql://postgres:postgres@127.0.0.1:55322/postgres`
- Studio: `http://127.0.0.1:55323`
- Mailpit: `http://127.0.0.1:55324`

Copy `supabase/.env.example` to an untracked `supabase/.env` and replace its placeholders before serving Edge Functions. The local stack and all migrations are started with:

```bash
npx supabase start --yes
npx supabase db lint --local
npx supabase test db
```

## Core financial rule

`current_balance = SUM(debit amounts) - SUM(credit amounts)`.

A debt/opening balance is debit; a payment is credit. Entries cannot be updated or deleted. A correction creates an equal opposite-direction reversal entry. Confirmation and dispute state do not silently change the financial fact.

## Security boundary

- Never ship a secret/service-role key in Flutter, Web, or desktop clients.
- The public schema contains no searchable raw phone number.
- Phone lookup uses HMAC; phone display/recovery uses AES-GCM ciphertext in `private.customer_contacts`.
- Use Edge Functions for customer lookup/create, signed uploads, PDF generation, and workers.
- Account creation and password recovery must use the WhatsApp OTP Edge Functions; direct Supabase sign-up is disabled.
- OTP requests are limited by phone and source address, expire after five minutes, allow five attempts, and are invalidated when a newer challenge is issued.
- `SUPABASE_SERVICE_ROLE_KEY` is runtime-injected only; it must never be placed in source control or a mobile build.
- RLS is enabled on every exposed table; direct ledger inserts are not granted to clients.
- Consolidated customer statements are never visible to merchants.

## Important implementation notes

- Run migrations in a fresh Supabase development project and add pgTAP tests before production deployment.
- Backfill `profiles` and `customers` for Auth users created before installing the Auth trigger.
- Add an idempotency UUID from the mobile app to every ledger command (`client_request_id`).
- For offline mode, retain failed commands locally and retry with the same idempotency UUID.
- Do not calculate the authoritative balance on the mobile device; use the database view/RPC result.
- Store timestamps in UTC (`timestamptz`) and render them in the business timezone.

## Recommended test cases

- A merchant cannot read another business's customers or entries.
- A customer sees all linked businesses but no other customer's data.
- A merchant never sees the customer's other businesses.
- Duplicate `client_request_id` cannot create two financial entries.
- An entry cannot be updated or deleted.
- A reversal exactly offsets the original entry and cannot itself be reversed.
- Payment exceeding the current balance is rejected.
- Customer confirmation cannot be inserted by a merchant.
- Only one active dispute can be opened per entry through the command RPC.
- Storage objects are inaccessible without the corresponding metadata authorization.

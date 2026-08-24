# ERD — Debt Ledger MVP

```mermaid
erDiagram
  AUTH_USERS ||--|| PROFILES : has
  AUTH_USERS o|--|| CUSTOMERS : owns_global_account
  CUSTOMERS ||--o| CUSTOMER_CONTACTS : private_contact

  AUTH_USERS ||--o{ BUSINESSES : owns
  BUSINESSES ||--o{ BUSINESS_MEMBERS : has
  AUTH_USERS ||--o{ BUSINESS_MEMBERS : joins

  BUSINESSES ||--o{ BUSINESS_CUSTOMERS : keeps_ledger_for
  CUSTOMERS ||--o{ BUSINESS_CUSTOMERS : linked_to
  BUSINESS_CUSTOMERS ||--o{ CUSTOMER_LINK_REQUESTS : receives
  CUSTOMERS ||--o{ CUSTOMER_LINK_REQUESTS : target

  BUSINESS_CUSTOMERS ||--o{ LEDGER_ENTRIES : contains
  BUSINESSES ||--o{ LEDGER_ENTRIES : tenant
  CUSTOMERS ||--o{ LEDGER_ENTRIES : debtor
  LEDGER_ENTRIES ||--|| LEDGER_ENTRY_STATE : projected_state
  LEDGER_ENTRIES ||--o{ LEDGER_ENTRY_EVENTS : history
  LEDGER_ENTRIES ||--o| ENTRY_CONFIRMATIONS : confirmed_by_customer
  LEDGER_ENTRIES o|--o| LEDGER_ENTRIES : reversed_by

  LEDGER_ENTRIES ||--o{ DISPUTES : disputed
  DISPUTES ||--|| DISPUTE_STATE : projected_state
  DISPUTES ||--o{ DISPUTE_EVENTS : history
  DISPUTES ||--o{ DISPUTE_MESSAGES : discussion

  FILES ||--o{ LEDGER_ENTRY_FILES : attached
  LEDGER_ENTRIES ||--o{ LEDGER_ENTRY_FILES : has
  FILES ||--o{ DISPUTE_MESSAGE_FILES : attached
  DISPUTE_MESSAGES ||--o{ DISPUTE_MESSAGE_FILES : has

  AUTH_USERS ||--o{ DEVICE_PUSH_TOKENS : registers
  AUTH_USERS ||--o{ NOTIFICATIONS : receives
  NOTIFICATIONS ||--|| NOTIFICATION_OUTBOX : delivered_by
  BUSINESS_CUSTOMERS ||--o{ REMINDERS : receives

  CUSTOMERS ||--o{ STATEMENTS : owns
  BUSINESS_CUSTOMERS o|--o{ STATEMENTS : business_scope
  STATEMENTS ||--o{ STATEMENT_ITEMS : snapshots
  LEDGER_ENTRIES ||--o{ STATEMENT_ITEMS : source

  AUTH_USERS ||--o{ USER_CONSENTS : grants
```

## Relationship rules

- A Supabase Auth user can be a merchant, customer, or both.
- Every registered user gets one global `customers` row; unregistered customers also get a row with `user_id = null`.
- `business_customers` is the tenant-safe bridge. A merchant only sees rows for their business; a customer sees linked rows belonging to their global account.
- `ledger_entries` is append-only. Reversal is a new entry pointing to `reversal_of_entry_id`.
- Confirmation, dispute, and reversal history are never overwritten; projection tables exist only for fast UI reads.
- Phone data is not stored in `public`; encrypted phone ciphertext and HMAC lookup values live in `private.customer_contacts`.

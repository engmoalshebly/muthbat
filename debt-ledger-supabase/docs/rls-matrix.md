# RLS access matrix

| Resource | Merchant member | Linked customer | Other business | Anonymous |
|---|---:|---:|---:|---:|
| Business | Read own business | Read linked business | Denied | Denied |
| Business customer | Read own tenant | Read own linked row | Denied | Denied |
| Ledger entries/state/events | Read own tenant | Read entries for own customer ID | Denied | Denied |
| Create debt/payment | RPC + role check | Denied | Denied | Denied |
| Reverse entry | Owner/Admin/Accountant RPC | Denied | Denied | Denied |
| Confirm entry | Denied | Customer-only RPC | Denied | Denied |
| Open dispute | Denied | Customer-only RPC | Denied | Denied |
| Resolve dispute | Owner/Admin/Accountant RPC | Denied | Denied | Denied |
| Notifications | Own only | Own only | Denied | Denied |
| Private attachments | Tenant-authorized | Customer-authorized | Denied | Denied |
| Consolidated statement | Denied | Own only | Denied | Verification via Edge Function only |

## Role permissions

- `owner`: all business commands.
- `admin`: all business commands except ownership transfer.
- `accountant`: create entries, reverse entries, resolve disputes, statements.
- `cashier`: create debts and payments, no reversals.
- `collector`: reminders and dispute messages, no ledger mutation.
- `viewer`: read-only.

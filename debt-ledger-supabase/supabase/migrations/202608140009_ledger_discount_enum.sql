-- Debt Ledger MVP - Introduce a customer discount ledger type.
-- Kept separate because PostgreSQL requires enum values to commit before constraints use them.
alter type public.ledger_entry_type add value if not exists 'discount' after 'payment';


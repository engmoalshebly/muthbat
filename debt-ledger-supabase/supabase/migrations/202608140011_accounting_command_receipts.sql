-- Debt Ledger MVP - Allow accounting commands to participate in offline idempotency receipts.
begin;

alter table public.command_receipts drop constraint command_receipts_command_type_check;
alter table public.command_receipts add constraint command_receipts_command_type_check check (
  command_type in (
    'create_ledger_entry','reverse_ledger_entry','confirm_ledger_entry','open_dispute',
    'add_dispute_message','resolve_dispute','apply_customer_discount','post_manual_journal'
  )
);

commit;

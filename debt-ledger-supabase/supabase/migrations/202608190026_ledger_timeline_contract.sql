-- Keep the timeline view compatible with the mobile sync projection.
-- Existing columns stay in the same order; new contract columns are appended.
begin;

create or replace view public.ledger_timeline as
select
  le.id,
  le.business_id,
  le.business_customer_id,
  le.customer_id,
  le.entry_type,
  le.direction,
  le.amount,
  le.currency_code,
  le.description,
  le.occurred_at,
  le.due_date,
  le.external_reference,
  le.reversal_of_entry_id,
  le.client_request_id,
  le.source_device_id,
  le.created_by_user_id,
  le.created_at,
  les.confirmation_status,
  les.dispute_status,
  les.is_reversed,
  les.reversal_entry_id,
  le.category,
  le.payment_method,
  le.reference_number,
  le.bank_or_agent_name,
  le.attachment_url
from public.ledger_entries le
join public.ledger_entry_state les on les.entry_id = le.id;

commit;

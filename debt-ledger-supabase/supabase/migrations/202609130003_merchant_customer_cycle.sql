-- Phase 7: owner-managed customer profiles and customer-visible dispute result.
begin;

create or replace function public.update_business_customer_profile(
  p_business_customer_id uuid,
  p_display_name text,
  p_note text default null,
  p_credit_limit numeric default null,
  p_default_due_days smallint default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_customer public.business_customers%rowtype;
begin
  select * into v_customer from public.business_customers
  where id = p_business_customer_id for update;
  if not found or not private.is_business_member(v_customer.business_id, array['owner']::public.business_role[]) then
    raise exception 'Owner permission required' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_display_name, ''))) not between 2 and 120
    or length(coalesce(p_note, '')) > 2000
    or p_credit_limit < 0
    or p_default_due_days not between 0 and 3650 then
    raise exception 'Invalid customer profile' using errcode = '22023';
  end if;
  update public.business_customers set
    local_display_name = trim(p_display_name),
    local_note = nullif(trim(p_note), ''),
    credit_limit = p_credit_limit,
    default_due_days = p_default_due_days,
    updated_at = now()
  where id = p_business_customer_id;
  return jsonb_build_object('updated', true, 'business_customer_id', p_business_customer_id);
end;
$$;

create or replace function public.archive_business_customer(p_business_customer_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_customer public.business_customers%rowtype;
begin
  select * into v_customer from public.business_customers
  where id = p_business_customer_id for update;
  if not found or not private.is_business_member(v_customer.business_id, array['owner']::public.business_role[]) then
    raise exception 'Owner permission required' using errcode = '42501';
  end if;
  update public.business_customers set is_archived = true, updated_at = now()
  where id = p_business_customer_id;
  update public.customer_link_requests set status = 'cancelled', updated_at = now()
  where business_customer_id = p_business_customer_id and status = 'pending';
  return jsonb_build_object('archived', true, 'business_customer_id', p_business_customer_id);
end;
$$;

revoke all on function public.update_business_customer_profile(uuid,text,text,numeric,smallint) from public, anon;
grant execute on function public.update_business_customer_profile(uuid,text,text,numeric,smallint) to authenticated;
revoke all on function public.archive_business_customer(uuid) from public, anon;
grant execute on function public.archive_business_customer(uuid) to authenticated;

create or replace view public.ledger_timeline as
select
  le.id, le.business_id, le.business_customer_id, le.customer_id,
  le.entry_type, le.direction, le.amount, le.currency_code, le.description,
  le.occurred_at, le.due_date, le.external_reference,
  le.reversal_of_entry_id, le.client_request_id, le.source_device_id,
  le.created_by_user_id, le.created_at, les.confirmation_status,
  les.dispute_status, les.is_reversed, les.reversal_entry_id,
  le.category, le.payment_method, le.reference_number,
  le.bank_or_agent_name, le.attachment_url,
  ds.resolution_note as dispute_resolution_note,
  ds.resolved_at as dispute_resolved_at
from public.ledger_entries le
join public.ledger_entry_state les on les.entry_id = le.id
left join public.disputes d on d.entry_id = le.id
left join public.dispute_state ds on ds.dispute_id = d.id;

commit;

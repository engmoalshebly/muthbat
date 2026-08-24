-- Atomic creation for a business customer without a phone number.
-- Phone-backed customers continue through customer-directory for PII
-- normalization, hashing, and encryption.
begin;

create or replace function private.command_create_business_customer_direct(
  p_business_id uuid,
  p_local_display_name text,
  p_credit_limit numeric default null,
  p_default_due_days smallint default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer_id uuid;
  v_business_customer_id uuid;
begin
  if not private.is_business_member(
    p_business_id,
    array['owner','admin','accountant','cashier']::public.business_role[]
  ) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  if p_local_display_name is null
     or char_length(trim(p_local_display_name)) not between 2 and 120 then
    raise exception 'Customer name must be between 2 and 120 characters'
      using errcode = '22023';
  end if;
  if p_credit_limit is not null and p_credit_limit < 0 then
    raise exception 'Credit limit cannot be negative' using errcode = '22023';
  end if;
  if p_default_due_days is not null
     and (p_default_due_days < 0 or p_default_due_days > 3650) then
    raise exception 'Due days must be between 0 and 3650' using errcode = '22023';
  end if;

  insert into public.customers default values returning id into v_customer_id;

  insert into public.business_customers(
    business_id, customer_id, local_display_name, credit_limit,
    default_due_days, link_status, created_by_user_id
  ) values (
    p_business_id, v_customer_id, trim(p_local_display_name), p_credit_limit,
    p_default_due_days, 'unlinked'::public.customer_link_status, auth.uid()
  )
  on conflict (business_id, customer_id) do update
    set local_display_name = excluded.local_display_name,
        credit_limit = coalesce(excluded.credit_limit, public.business_customers.credit_limit),
        default_due_days = coalesce(excluded.default_due_days, public.business_customers.default_due_days),
        is_archived = false
  returning id into v_business_customer_id;

  return v_business_customer_id;
end;
$$;

create or replace function public.create_business_customer_direct(
  p_business_id uuid,
  p_local_display_name text,
  p_credit_limit numeric default null,
  p_default_due_days smallint default null
)
returns uuid
language sql
set search_path = ''
as $$
  select private.command_create_business_customer_direct(
    p_business_id, p_local_display_name, p_credit_limit, p_default_due_days
  )
$$;

grant execute on function public.create_business_customer_direct(uuid,text,numeric,smallint) to authenticated;
grant execute on function private.command_create_business_customer_direct(uuid,text,numeric,smallint) to authenticated;

commit;

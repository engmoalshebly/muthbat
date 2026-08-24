-- Keep the customer directory idempotent without silently reusing an active
-- relationship when a merchant attempts to add the same phone twice.
begin;

create or replace function private.command_add_business_customer(
  p_business_id uuid,
  p_customer_id uuid,
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
  v_id uuid;
  v_link public.customer_link_status;
  v_existing public.business_customers%rowtype;
begin
  if not private.is_business_member(
    p_business_id,
    array['owner','admin','accountant','cashier']::public.business_role[]
  ) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.customers
    where id = p_customer_id and status = 'active'
  ) then
    raise exception 'Customer not found';
  end if;

  select * into v_existing
  from public.business_customers
  where business_id = p_business_id
    and customer_id = p_customer_id
  for update;
  if found and not v_existing.is_archived then
    raise exception 'customer_exists';
  elsif found then
    update public.business_customers
    set local_display_name = trim(p_local_display_name),
        credit_limit = coalesce(p_credit_limit, credit_limit),
        default_due_days = coalesce(p_default_due_days, default_due_days),
        is_archived = false
    where id = v_existing.id
    returning id into v_id;
    return v_id;
  end if;

  select case
    when user_id is null then 'unlinked'::public.customer_link_status
    else 'pending'::public.customer_link_status
  end
  into v_link
  from public.customers
  where id = p_customer_id;

  insert into public.business_customers(
    business_id,
    customer_id,
    local_display_name,
    credit_limit,
    default_due_days,
    link_status,
    created_by_user_id
  ) values (
    p_business_id,
    p_customer_id,
    trim(p_local_display_name),
    p_credit_limit,
    p_default_due_days,
    v_link,
    (select auth.uid())
  )
  on conflict (business_id, customer_id) do nothing
  returning id into v_id;

  if v_id is null then
    raise exception 'customer_exists';
  end if;

  return v_id;
end;
$$;

commit;

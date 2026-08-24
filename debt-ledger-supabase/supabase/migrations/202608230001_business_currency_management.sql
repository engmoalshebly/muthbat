-- Safe post-onboarding currency management.
begin;

create or replace function public.update_business_currencies(
  p_business_id uuid,
  p_additional_currencies text[]
)
returns text[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base text;
  v_requested text[];
  v_used_removed text[];
begin
  if not private.is_business_member(
    p_business_id,
    array['owner','admin']::public.business_role[]
  ) then
    raise exception 'Not authorized to manage business currencies'
      using errcode = '42501';
  end if;

  select currency_code into v_base
  from public.businesses
  where id = p_business_id and status = 'active'
  for update;

  if v_base is null then
    raise exception 'Business not found' using errcode = 'P0002';
  end if;

  select coalesce(array_agg(distinct upper(trim(code)) order by upper(trim(code))), '{}')
  into v_requested
  from unnest(coalesce(p_additional_currencies, '{}'::text[])) code
  where trim(code) <> '' and upper(trim(code)) <> v_base;

  if not private.is_valid_additional_currencies(v_requested, v_base) then
    raise exception 'Invalid currency list' using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct currency_code), '{}')
  into v_used_removed
  from public.ledger_entries
  where business_id = p_business_id
    and currency_code <> v_base
    and not (currency_code = any(v_requested));

  if cardinality(v_used_removed) > 0 then
    raise exception 'Currencies with ledger entries cannot be disabled: %',
      array_to_string(v_used_removed, ', ')
      using errcode = '23514';
  end if;

  update public.businesses
  set additional_currencies = v_requested,
      updated_at = now()
  where id = p_business_id;

  return v_requested;
end;
$$;

revoke all on function public.update_business_currencies(uuid,text[]) from public;
grant execute on function public.update_business_currencies(uuid,text[]) to authenticated;

commit;

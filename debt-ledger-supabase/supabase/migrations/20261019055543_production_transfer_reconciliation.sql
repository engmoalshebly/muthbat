-- Reconcile only imported entries. New activity in the destination business
-- must not invalidate an already committed, immutable import.
begin;
create or replace function public.verify_local_notebook_import(p_notebook_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_import private.local_notebook_imports%rowtype;
  v_business uuid;
  v_customers integer;
  v_entries integer;
  v_categories integer;
  v_balance numeric;
  v_expected_balance numeric;
  v_valid boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='28000'; end if;
  select * into v_import from private.local_notebook_imports
    where user_id=auth.uid() and notebook_id=p_notebook_id;
  if not found then raise exception 'Notebook import not found' using errcode='P0002'; end if;
  v_business := (v_import.result->>'business_id')::uuid;
  select coalesce(sum(case when e->>'direction'='debit' then (e->>'minor')::numeric else -(e->>'minor')::numeric end),0)
    into v_expected_balance from jsonb_array_elements(v_import.snapshot->'entries') e;

  select count(*)::integer,coalesce(sum(case when le.direction='debit' then le.amount else -le.amount end)*10000,0)
    into v_entries,v_balance
    from jsonb_array_elements(v_import.snapshot->'entries') source
    join public.ledger_entries le on le.business_id=v_business and le.client_request_id=(source->>'id')::uuid;
  select count(*)::integer into v_categories
    from jsonb_array_elements(v_import.snapshot->'entries') source
    join public.ledger_entries le on le.business_id=v_business and le.client_request_id=(source->>'id')::uuid
    join public.local_import_entry_categories c on c.entry_id=le.id and c.label=source->>'category';
  if v_import.result->'customer_map' is not null then
    select count(*)::integer into v_customers
      from jsonb_each_text(v_import.result->'customer_map') m
      join public.business_customers bc on bc.id=m.value::uuid and bc.business_id=v_business;
  else
    -- Legacy receipts lack a map. Verify actual relationships by their
    -- imported names rather than trusting an acknowledged count as evidence.
    select count(*)::integer into v_customers
      from jsonb_array_elements(v_import.snapshot->'customers') source
      where exists(select 1 from public.business_customers bc
        where bc.business_id=v_business and bc.local_display_name=source->>'name');
  end if;
  select not exists(
    select 1 from jsonb_array_elements(v_import.snapshot->'entries') source
    left join public.ledger_entries le on le.business_id=v_business and le.client_request_id=(source->>'id')::uuid
    where le.id is null or le.amount*10000 is distinct from (source->>'minor')::numeric
      or le.direction::text is distinct from source->>'direction'
      or le.entry_type::text is distinct from source->>'type'
      or le.currency_code is distinct from v_import.snapshot->>'currency'
      or le.description is distinct from source->>'description'
      or (v_import.result->'customer_map' is not null and le.business_customer_id is distinct from
        (v_import.result->'customer_map'->>(source->>'customer_id'))::uuid)
  ) into v_valid;
  return jsonb_build_object(
    'verified',v_valid and v_entries=jsonb_array_length(v_import.snapshot->'entries')
      and v_customers=jsonb_array_length(v_import.snapshot->'customers')
      and v_categories=(select count(*) from jsonb_array_elements(v_import.snapshot->'entries') e where e->>'category' is not null)
      and v_balance=v_expected_balance,
    'business_id',v_business,'customer_count',v_customers,'entry_count',v_entries,
    'category_count',v_categories,'balance_minor',v_balance,'currency',v_import.snapshot->>'currency');
end;
$$;
revoke all on function public.verify_local_notebook_import(uuid) from public,anon;
grant execute on function public.verify_local_notebook_import(uuid) to authenticated;
create or replace function public.local_notebook_import_version()
returns integer language sql stable set search_path='' as $$ select 6 $$;
commit;

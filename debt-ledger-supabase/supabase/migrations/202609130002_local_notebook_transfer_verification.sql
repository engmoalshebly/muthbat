-- Phase 6: expose a server-side, account-scoped reconciliation checkpoint.
-- The import itself remains one atomic transaction; this function lets a
-- client safely retry after an ambiguous response and only mark its local
-- notebook complete after every persisted projection matches the snapshot.
begin;

create or replace function public.local_notebook_import_version()
returns integer language sql stable set search_path = '' as $$ select 3 $$;

create or replace function public.verify_local_notebook_import(p_notebook_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_import private.local_notebook_imports%rowtype;
  v_business uuid;
  v_expected_customers integer;
  v_expected_entries integer;
  v_expected_categories integer;
  v_expected_balance_minor numeric;
  v_customer_count integer;
  v_entry_count integer;
  v_category_count integer;
  v_balance_minor numeric;
  v_currency text;
begin
  if v_user is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  select * into v_import
  from private.local_notebook_imports
  where user_id = v_user and notebook_id = p_notebook_id;
  if not found then
    raise exception 'Notebook import not found' using errcode = 'P0002';
  end if;

  v_business := (v_import.result->>'business_id')::uuid;
  v_expected_customers := jsonb_array_length(v_import.snapshot->'customers');
  v_expected_entries := jsonb_array_length(v_import.snapshot->'entries');
  select count(*)::integer into v_expected_categories
  from jsonb_array_elements(v_import.snapshot->'entries') e
  where e->>'category' is not null;
  select coalesce(sum(
    case when e->>'direction' = 'debit'
      then (e->>'minor')::numeric else -(e->>'minor')::numeric end
  ), 0) into v_expected_balance_minor
  from jsonb_array_elements(v_import.snapshot->'entries') e;

  select count(*)::integer into v_customer_count
  from public.business_customers where business_id = v_business;
  select count(*)::integer,
         coalesce(sum(case when direction = 'debit' then amount else -amount end) * 10000, 0),
         min(currency_code)
    into v_entry_count, v_balance_minor, v_currency
  from public.ledger_entries where business_id = v_business;
  select count(*)::integer into v_category_count
  from public.local_import_entry_categories c
  join public.ledger_entries e on e.id = c.entry_id
  where e.business_id = v_business;

  return jsonb_build_object(
    'verified', v_customer_count = v_expected_customers
      and v_entry_count = v_expected_entries
      and v_category_count = v_expected_categories
      and v_balance_minor = v_expected_balance_minor
      and coalesce(v_currency, v_import.snapshot->>'currency') = v_import.snapshot->>'currency',
    'business_id', v_business,
    'customer_count', v_customer_count,
    'entry_count', v_entry_count,
    'category_count', v_category_count,
    'balance_minor', v_balance_minor,
    'currency', coalesce(v_currency, v_import.snapshot->>'currency')
  );
end;
$$;

revoke all on function public.local_notebook_import_version() from public, anon;
grant execute on function public.local_notebook_import_version() to authenticated;
revoke all on function public.verify_local_notebook_import(uuid) from public, anon;
grant execute on function public.verify_local_notebook_import(uuid) to authenticated;

commit;

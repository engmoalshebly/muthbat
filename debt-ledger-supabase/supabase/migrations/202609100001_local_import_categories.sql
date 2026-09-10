-- An immutable local snapshot is imported atomically. A lost HTTP response can
-- be retried without creating a second business, customer, or financial entry.
begin;

create table if not exists private.local_notebook_imports (
  user_id uuid not null references auth.users(id),
  notebook_id uuid not null,
  snapshot jsonb not null,
  result jsonb not null,
  primary key (user_id, notebook_id)
);
revoke all on private.local_notebook_imports from public, anon, authenticated;

create or replace function public.local_notebook_import_version()
returns integer language sql stable set search_path = '' as $$ select 2 $;
revoke all on function public.local_notebook_import_version() from public, anon;
grant execute on function public.local_notebook_import_version() to authenticated;

-- Imported labels are separate from the server's fixed accounting category.
-- They are immutable, and readable only when the underlying ledger entry is visible.
create table public.local_import_entry_categories (
  entry_id uuid primary key references public.ledger_entries(id),
  label text not null check (length(trim(label)) between 2 and 80)
);
alter table public.local_import_entry_categories enable row level security;
revoke all on public.local_import_entry_categories from public, anon, authenticated;
grant select on public.local_import_entry_categories to authenticated;
create policy read_visible_entry_category on public.local_import_entry_categories
for select to authenticated using (
  exists (select 1 from public.ledger_entries e where e.id = entry_id)
);
create trigger local_import_categories_immutable
before update or delete on public.local_import_entry_categories
for each row execute function private.prevent_update_delete();

create or replace function public.import_local_notebook(p_notebook jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_notebook uuid;
  v_business uuid;
  v_customer uuid;
  v_entry uuid;
  v_original uuid;
  v_snapshot jsonb;
  v_existing private.local_notebook_imports%rowtype;
  v_result jsonb;
  v_customer_map jsonb := '{}';
  v_entry_map jsonb := '{}';
  v_reversed jsonb := '{}';
  v_entry_sources jsonb := '{}';
  v_row jsonb;
  v_source jsonb;
  v_id text;
  v_amount numeric;
  v_expected numeric;
  v_actual numeric;
  v_category_count integer := 0;
begin
  if v_user is null then raise exception 'Authentication required' using errcode='28000'; end if;
  if p_notebook->>'owner_id' is distinct from v_user::text then raise exception 'Notebook belongs to another account' using errcode='42501'; end if;
  if p_notebook->>'version' is distinct from '1'
    or p_notebook->>'currency' not in ('YER','SAR','USD')
    or p_notebook->>'currency' is null
    or length(trim(coalesce(p_notebook->>'name',''))) not between 2 and 120
    or jsonb_typeof(p_notebook->'customers') is distinct from 'array'
    or jsonb_typeof(p_notebook->'entries') is distinct from 'array' then
    raise exception 'Invalid notebook' using errcode='22023';
  end if;
  if jsonb_array_length(p_notebook->'entries') > 20000 or jsonb_array_length(p_notebook->'customers') > 5000 then
    raise exception 'Notebook exceeds import limit' using errcode='22023';
  end if;
  v_notebook := (p_notebook->>'id')::uuid;
  if v_notebook is null then raise exception 'Notebook id required'; end if;
  v_snapshot := jsonb_build_object('id',v_notebook,'name',p_notebook->>'name','currency',p_notebook->>'currency',
    'customers',p_notebook->'customers','entries',p_notebook->'entries');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user::text||v_notebook::text,0));
  select * into v_existing from private.local_notebook_imports where user_id=v_user and notebook_id=v_notebook;
  if found then
    if v_existing.snapshot is distinct from v_snapshot then raise exception 'Imported snapshot cannot be changed' using errcode='22023'; end if;
    return v_existing.result;
  end if;

  v_business := private.command_create_business(p_notebook->>'name','grocery',p_notebook->>'currency','YE',null,null,'{}');
  for v_row in select value from jsonb_array_elements(p_notebook->'customers') loop
    v_id := (v_row->>'id')::uuid::text;
    if v_id is null or v_customer_map ? v_id then raise exception 'Invalid or duplicate customer'; end if;
    v_customer := private.command_create_business_customer_direct(v_business,v_row->>'name',null,null);
    v_customer_map := v_customer_map || jsonb_build_object(v_id,v_customer);
  end loop;

  for v_row in select value from jsonb_array_elements(p_notebook->'entries') loop
    v_id := (v_row->>'id')::uuid::text;
    if v_id is null or v_entry_map ? v_id then raise exception 'Invalid or duplicate entry'; end if;
    v_customer := (v_customer_map->>(v_row->>'customer_id'))::uuid;
    if v_customer is null then raise exception 'Unknown customer'; end if;
    if coalesce(v_row->>'minor','') !~ '^[0-9]+$' then raise exception 'Invalid amount'; end if;
    v_amount := (v_row->>'minor')::numeric / 10000;
    if v_amount <= 0 or v_amount > 99999999999.9999 then raise exception 'Amount out of range'; end if;
    if length(trim(coalesce(v_row->>'description',''))) not between 2 and 500 then raise exception 'Invalid description'; end if;
    if v_row->'category' is not null and v_row->'category' <> 'null'::jsonb then
      if jsonb_typeof(v_row->'category') <> 'string'
        or length(trim(v_row->>'category')) not between 2 and 80 then
        raise exception 'Invalid category' using errcode='22023';
      end if;
    end if;
    if v_row->>'type' = 'reversal' then
      v_original := (v_entry_map->>(v_row->>'reverses'))::uuid;
      v_source := v_entry_sources->(v_row->>'reverses');
      if v_original is null or v_reversed ? (v_row->>'reverses') or v_source->>'type' = 'reversal'
        or v_source->>'customer_id' is distinct from v_row->>'customer_id'
        or v_source->>'minor' is distinct from v_row->>'minor'
        or v_row->>'direction' is distinct from (case when v_source->>'direction'='debit' then 'credit' else 'debit' end) then
        raise exception 'Invalid reversal';
      end if;
      v_entry := public.reverse_ledger_entry(v_original,v_row->>'description',v_id::uuid);
      v_reversed := v_reversed || jsonb_build_object(v_row->>'reverses',true);
    elsif v_row->>'type' in ('debt','payment','discount') then
      if v_row->>'direction' is distinct from (case when v_row->>'type'='debt' then 'debit' else 'credit' end)
        or (v_row->>'reverses') is not null then raise exception 'Invalid entry direction'; end if;
      if v_row->>'occurred_at' is null then raise exception 'Entry date required'; end if;
      if v_row->>'type'='discount' then
        v_entry := public.apply_customer_discount(v_customer,v_amount,v_row->>'description',(v_row->>'occurred_at')::timestamptz,v_id::uuid,p_notebook->>'currency');
      else
        v_entry := public.create_ledger_entry(
          p_business_customer_id=>v_customer,p_entry_type=>(v_row->>'type')::public.ledger_entry_type,
          p_amount=>v_amount,p_description=>v_row->>'description',p_occurred_at=>(v_row->>'occurred_at')::timestamptz,
          p_client_request_id=>v_id::uuid,p_currency_code=>p_notebook->>'currency');
      end if;
    else raise exception 'Invalid entry type';
    end if;
    if v_row->>'category' is not null then
      insert into public.local_import_entry_categories(entry_id,label)
      values(v_entry,v_row->>'category');
      v_category_count := v_category_count + 1;
    end if;
    v_entry_map := v_entry_map || jsonb_build_object(v_id,v_entry);
    v_entry_sources := v_entry_sources || jsonb_build_object(v_id,v_row);
  end loop;

  -- Verify each customer independently so discrepancies cannot cancel out.
  for v_row in select value from jsonb_array_elements(p_notebook->'customers') loop
    select coalesce(sum((case when value->>'direction'='debit' then 1 else -1 end)*(value->>'minor')::numeric/10000),0)
      into v_expected from jsonb_array_elements(p_notebook->'entries') where value->>'customer_id'=v_row->>'id';
    select coalesce(sum(case when direction='debit' then amount else -amount end),0)
      into v_actual from public.ledger_entries where business_customer_id=(v_customer_map->>(v_row->>'id'))::uuid;
    if v_actual is distinct from v_expected then raise exception 'Balance verification failed'; end if;
  end loop;
  v_result := jsonb_build_object('business_id',v_business,'customer_count',jsonb_array_length(p_notebook->'customers'),'entry_count',jsonb_array_length(p_notebook->'entries'),'category_count',v_category_count);
  insert into private.local_notebook_imports(user_id,notebook_id,snapshot,result) values(v_user,v_notebook,v_snapshot,v_result);
  return v_result;
end;
$$;
revoke all on function public.import_local_notebook(jsonb) from public, anon;
grant execute on function public.import_local_notebook(jsonb) to authenticated;
commit;

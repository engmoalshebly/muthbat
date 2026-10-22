-- Phone PII is prepared by an authenticated Edge Function. Only the service
-- role can stage encrypted contacts; import still executes as the real caller.
begin;
create table private.local_notebook_contact_preparations (
  user_id uuid not null references auth.users(id),
  notebook_id uuid not null,
  token uuid not null unique default gen_random_uuid(),
  notebook jsonb not null,
  contacts jsonb not null,
  legacy_snapshot_matches boolean not null default false,
  expires_at timestamptz not null default now() + interval '1 hour',
  primary key(user_id,notebook_id)
);
alter table private.local_notebook_contact_preparations enable row level security;
revoke all on private.local_notebook_contact_preparations from public,anon,authenticated,service_role;

create or replace function public.service_prepare_local_notebook_import(p_user_id uuid,p_notebook jsonb,p_contacts jsonb,p_original_notebook jsonb default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_token uuid; v_legacy_matches boolean := false;
begin
  if p_notebook->>'owner_id' is distinct from p_user_id::text
    or jsonb_typeof(p_notebook->'customers') is distinct from 'array'
    or jsonb_typeof(p_contacts) is distinct from 'object' then
    raise exception 'Invalid preparation' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_array_elements(p_notebook->'customers') c where c ? 'phone') then
    raise exception 'Raw phone must not enter import storage' using errcode='22023';
  end if;
  -- A v3 upload may already exist after a lost response. Compare the original
  -- snapshot transiently inside this service-only PII boundary; never retain a
  -- second copy of its cleartext phones in preparation storage.
  select snapshot = jsonb_build_object('id',(p_original_notebook->>'id')::uuid,
    'name',p_original_notebook->>'name','currency',p_original_notebook->>'currency',
    'customers',p_original_notebook->'customers','entries',p_original_notebook->'entries')
    into v_legacy_matches from private.local_notebook_imports
    where user_id=p_user_id and notebook_id=(p_notebook->>'id')::uuid
      and result->'customer_map' is null;
  insert into private.local_notebook_contact_preparations(user_id,notebook_id,notebook,contacts,legacy_snapshot_matches)
  values(p_user_id,(p_notebook->>'id')::uuid,p_notebook,p_contacts,coalesce(v_legacy_matches,false))
  on conflict(user_id,notebook_id) do update set
    token=gen_random_uuid(), notebook=excluded.notebook, contacts=excluded.contacts,
    legacy_snapshot_matches=excluded.legacy_snapshot_matches,
    expires_at=now()+interval '1 hour'
  returning token into v_token;
  return v_token;
end;
$$;
revoke all on function public.service_prepare_local_notebook_import(uuid,jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.service_prepare_local_notebook_import(uuid,jsonb,jsonb,jsonb) to service_role;

create or replace function private.import_local_notebook_with_contacts(p_notebook jsonb, p_contacts jsonb, p_legacy_snapshot_matches boolean default false)
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
  v_customer_map jsonb := '{}'::jsonb;
  v_entry_map jsonb := '{}'::jsonb;
  v_reversed jsonb := '{}'::jsonb;
  v_entry_sources jsonb := '{}'::jsonb;
  v_row jsonb;
  v_source jsonb;
  v_id text;
  v_amount numeric;
  v_expected numeric;
  v_actual numeric;
  v_category_count integer := 0;
  v_identity uuid;
  v_contact jsonb;
  v_phone_count integer := 0;
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
    if p_legacy_snapshot_matches and v_existing.result->'customer_map' is null then
      v_business := (v_existing.result->>'business_id')::uuid;
      for v_row in select value from jsonb_array_elements(p_notebook->'customers') loop
        v_id := (v_row->>'id')::uuid::text;
        if (select count(*) from public.business_customers where business_id=v_business
          and local_display_name=v_row->>'name') <> 1 then
          raise exception 'Legacy contact requires review' using errcode='23505';
        end if;
        select id,customer_id into v_customer,v_identity from public.business_customers
          where business_id=v_business and local_display_name=v_row->>'name';
        if exists(select 1 from public.business_customers where id=v_customer
          and local_note is not null and local_note is distinct from nullif(trim(v_row->>'description'),'')) then
          raise exception 'Legacy customer note requires review' using errcode='23505';
        end if;
        v_contact := p_contacts->v_id;
        if v_row->>'phone_hash' is not null then
          if v_contact->>'phone_hash' is distinct from v_row->>'phone_hash' then
            raise exception 'Phone preparation required' using errcode='42501';
          end if;
          -- Financial history is immutable: never merge a legacy identity
          -- into a different registered phone owner as an import side effect.
          if exists(select 1 from private.customer_contacts where phone_hash=v_contact->>'phone_hash'
            and customer_id<>v_identity) then
            raise exception 'Legacy phone identity requires review' using errcode='23505';
          end if;
          perform private.service_upsert_customer_contact(v_identity,v_contact->>'phone_hash',
            (v_contact->>'phone_ciphertext')::bytea,v_contact->>'phone_last4',null,
            (v_contact->>'key_version')::smallint);
          v_phone_count := v_phone_count+1;
        end if;
        update public.business_customers set local_note=nullif(trim(v_row->>'description'),'') where id=v_customer;
        v_customer_map := v_customer_map || jsonb_build_object(v_id,v_customer);
      end loop;
      v_result := v_existing.result || jsonb_build_object('phone_count',v_phone_count,'customer_map',v_customer_map);
      update private.local_notebook_imports set snapshot=v_snapshot,result=v_result
        where user_id=v_user and notebook_id=v_notebook;
      return v_result;
    end if;
    if v_existing.snapshot is distinct from v_snapshot then raise exception 'Imported snapshot cannot be changed' using errcode='22023'; end if;
    return v_existing.result || jsonb_build_object('phone_count',coalesce(v_existing.result->'phone_count','0'::jsonb));
  end if;

  v_business := private.command_create_business(p_notebook->>'name','grocery',p_notebook->>'currency','YE',null,null,'{}');
  for v_row in select value from jsonb_array_elements(p_notebook->'customers') loop
    v_id := (v_row->>'id')::uuid::text;
    if v_id is null or v_customer_map ? v_id then raise exception 'Invalid or duplicate customer'; end if;
    if length(trim(coalesce(v_row->>'name',''))) not between 2 and 120 then
      raise exception 'Invalid customer name' using errcode='22023';
    end if;
    if length(coalesce(v_row->>'description','')) > 500 then
      raise exception 'Invalid customer description' using errcode='22023';
    end if;
    v_contact := p_contacts->v_id;
    if v_row->>'phone_hash' is not null then
      if v_contact->>'phone_hash' is distinct from v_row->>'phone_hash' then
        raise exception 'Phone preparation required' using errcode='42501';
      end if;
      select customer_id into v_identity from public.service_resolve_customer_phone(
        v_contact->>'phone_hash', (v_contact->>'phone_ciphertext')::bytea,
        v_contact->>'phone_last4', (v_contact->>'key_version')::smallint);
      if exists(select 1 from public.business_customers where business_id=v_business and customer_id=v_identity) then
        raise exception 'Duplicate customer phone in notebook' using errcode='22023';
      end if;
      v_customer := public.add_business_customer(v_business,v_identity,v_row->>'name',null,null);
      v_phone_count := v_phone_count + 1;
    else
      v_customer := private.command_create_business_customer_direct(v_business,v_row->>'name',null,null);
    end if;
    update public.business_customers set local_note=nullif(trim(v_row->>'description'),'') where id=v_customer;
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
  v_result := jsonb_build_object('business_id',v_business,'customer_count',jsonb_array_length(p_notebook->'customers'),'entry_count',jsonb_array_length(p_notebook->'entries'),'category_count',v_category_count,'phone_count',v_phone_count,'customer_map',v_customer_map);
  insert into private.local_notebook_imports(user_id,notebook_id,snapshot,result) values(v_user,v_notebook,v_snapshot,v_result);
  return v_result;
end;
$$;

revoke all on function private.import_local_notebook_with_contacts(jsonb,jsonb,boolean) from public,anon,authenticated,service_role;

create or replace function public.import_prepared_local_notebook(p_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_prepared private.local_notebook_contact_preparations%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='28000'; end if;
  select * into v_prepared from private.local_notebook_contact_preparations
    where token=p_token and user_id=auth.uid() and expires_at>now() for update;
  if not found then raise exception 'Import preparation unavailable' using errcode='42501'; end if;
  return private.import_local_notebook_with_contacts(v_prepared.notebook,v_prepared.contacts,v_prepared.legacy_snapshot_matches);
end;
$$;
revoke all on function public.import_prepared_local_notebook(uuid) from public,anon;
grant execute on function public.import_prepared_local_notebook(uuid) to authenticated;

-- Keep phone-free clients compatible, but never silently discard supplied PII.
create or replace function public.import_local_notebook(p_notebook jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from jsonb_array_elements(p_notebook->'customers') c
    where nullif(c->>'phone','') is not null or c->>'phone_hash' is not null) then
    raise exception 'Use the local-notebook-import Edge Function for phone contacts' using errcode='22023';
  end if;
  return private.import_local_notebook_with_contacts(p_notebook,'{}'::jsonb);
end;
$$;
revoke all on function public.import_local_notebook(jsonb) from public,anon;
grant execute on function public.import_local_notebook(jsonb) to authenticated;
create or replace function public.local_notebook_import_version()
returns integer language sql stable set search_path='' as $$ select 4 $$;
commit;

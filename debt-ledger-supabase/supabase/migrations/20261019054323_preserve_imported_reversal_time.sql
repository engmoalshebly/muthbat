-- Preserve local reversal occurrence times at insertion. Ordinary reversal
-- and dispute commands retain server time. Only the private importer supplies
-- an original date; currency policy and dispute lock ordering remain intact.
begin;
create or replace function private.command_reverse_ledger_entry_at(
  p_entry_id uuid,
  p_reason text,
  p_client_request_id uuid,
  p_allow_active_dispute boolean,
  p_occurred_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_original public.ledger_entries%rowtype;
  v_balance numeric(20,4);
  v_allow_credit boolean;
  v_id uuid;
  v_direction public.ledger_direction;
  v_request_id uuid := coalesce(p_client_request_id,gen_random_uuid());
begin
  if p_occurred_at is null or not isfinite(p_occurred_at) then
    raise exception 'Reversal date required' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  select * into v_original from public.ledger_entries where id=p_entry_id;
  if not found or v_original.entry_type='reversal' then raise exception 'Invalid original entry'; end if;
  perform 1 from public.business_customers
   where id=v_original.business_customer_id for update;
  select * into v_original from public.ledger_entries where id=p_entry_id for update;
  perform pg_advisory_xact_lock(hashtextextended(p_entry_id::text,0));
  if not private.is_business_member(v_original.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select id into v_id from public.ledger_entries
   where business_id=v_original.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  if exists(select 1 from public.ledger_entries where reversal_of_entry_id=p_entry_id) then
    raise exception 'Entry already reversed';
  end if;
  if not p_allow_active_dispute and exists(
    select 1 from public.disputes d join public.dispute_state ds on ds.dispute_id=d.id
     where d.entry_id=p_entry_id and ds.status in ('open','awaiting_merchant','awaiting_customer','escalated')
  ) then
    raise exception 'Entry has an active dispute; resolve it first';
  end if;
  if v_original.direction='debit' then
    select coalesce(sum(case when direction='debit' then amount else -amount end),0)
      into v_balance from public.ledger_entries
     where business_customer_id=v_original.business_customer_id
       and currency_code=v_original.currency_code;
    select allow_customer_credit_balance into v_allow_credit
      from public.business_accounting_settings where business_id=v_original.business_id;
    if v_balance-v_original.amount < 0 and not coalesce(v_allow_credit,true) then
      raise exception 'Reversal would push the customer balance below zero';
    end if;
  end if;
  v_direction:=case when v_original.direction='debit' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;
  insert into public.ledger_entries(
    business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,
    occurred_at,reversal_of_entry_id,client_request_id,created_by_user_id
  ) values(
    v_original.business_id,v_original.business_customer_id,v_original.customer_id,'reversal',v_direction,
    v_original.amount,v_original.currency_code,left(trim(p_reason),500),p_occurred_at,v_original.id,v_request_id,(select auth.uid())
  ) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'reverse_ledger_entry','accepted',v_id,
         jsonb_build_object('entry_id',v_id,'currency_code',v_original.currency_code))
  on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;


revoke all on function private.command_reverse_ledger_entry_at(uuid,text,uuid,boolean,timestamptz) from public,anon,authenticated,service_role;

-- Preserve the current command signature and existing grants. Ordinary calls
-- and trusted dispute resolution share the same guarded implementation.
create or replace function private.command_reverse_ledger_entry(
  p_entry_id uuid,p_reason text,p_client_request_id uuid default gen_random_uuid(),
  p_allow_active_dispute boolean default false
) returns uuid language sql security definer set search_path='' as $$
  select private.command_reverse_ledger_entry_at(p_entry_id,p_reason,p_client_request_id,p_allow_active_dispute,now());
$$;

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
      if v_row->>'occurred_at' is null then
        raise exception 'Reversal date required' using errcode='22023';
      end if;
      v_entry := private.command_reverse_ledger_entry_at(
        v_original,v_row->>'description',v_id::uuid,false,(v_row->>'occurred_at')::timestamptz);
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


create or replace function public.local_notebook_import_version()
returns integer language sql stable set search_path='' as $$ select 5 $$;
commit;

-- Run with psql -v ON_ERROR_STOP=1 against a disposable/local migrated DB.
-- All fixtures and assertions are rolled back. No real phone data is used.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','a1900000-0000-0000-0000-000000000001','authenticated','authenticated','transfer-test@example.test','unused',now(),'{}','{"display_name":"Transfer test","user_type":"merchant"}',now(),now());
select set_config('test.notebook', jsonb_build_object(
  'version',1,'id','a1900000-0000-0000-0000-000000000002',
  'owner_id','a1900000-0000-0000-0000-000000000001','name','Imported contact test','currency','YER',
  'customers',jsonb_build_array(jsonb_build_object('id','a1900000-0000-0000-0000-000000000003',
    'name','عميل الاختبار','phone_hash',repeat('a',64),'description','عنوان العميل وملاحظاته')),
  'entries',jsonb_build_array(jsonb_build_object('id','a1900000-0000-0000-0000-000000000004',
    'customer_id','a1900000-0000-0000-0000-000000000003','type','debt','direction','debit',
    'minor',1000000,'description','دين الاختبار','occurred_at',now()))
)::text,true);
select set_config('test.contacts', jsonb_build_object('a1900000-0000-0000-0000-000000000003',
  jsonb_build_object('phone_hash',repeat('a',64),'phone_ciphertext','\x01020304',
    'phone_last4','3456','key_version',1))::text,true);

set local role service_role;
select set_config('test.token',public.service_prepare_local_notebook_import(
  'a1900000-0000-0000-0000-000000000001',current_setting('test.notebook')::jsonb,
  current_setting('test.contacts')::jsonb)::text,true);
set local role authenticated;
select set_config('request.jwt.claim.sub','a1900000-0000-0000-0000-000000000001',true);
select set_config('test.result',public.import_prepared_local_notebook(current_setting('test.token')::uuid)::text,true);
do $$ begin
  assert (current_setting('test.result')::jsonb->>'phone_count')::int=1, 'Phone count acknowledged';
  assert public.import_prepared_local_notebook(current_setting('test.token')::uuid)=current_setting('test.result')::jsonb, 'Same request returns receipt';
  assert (public.verify_local_notebook_import('a1900000-0000-0000-0000-000000000002')->>'verified')::boolean, 'Financial verification passes';
  begin
    perform public.service_prepare_local_notebook_import('a1900000-0000-0000-0000-000000000001','{}','{}');
    raise exception 'Authenticated caller could stage trusted contacts';
  exception when insufficient_privilege then null; end;
  begin
    perform public.import_local_notebook(current_setting('test.notebook')::jsonb);
    raise exception 'Unprepared caller could inject phone hash';
  exception when invalid_parameter_value then null; end;
end $$;
reset role;
do $$ declare v_bc public.business_customers%rowtype; begin
  select * into strict v_bc from public.business_customers
    where business_id=(current_setting('test.result')::jsonb->>'business_id')::uuid;
  assert v_bc.local_note='عنوان العميل وملاحظاته', 'Description preserved';
  assert exists(select 1 from private.customer_contacts where customer_id=v_bc.customer_id
    and phone_hash=repeat('a',64) and phone_last4='3456' and phone_ciphertext='\x01020304'::bytea), 'Encrypted contact attached to actual identity';
  assert (select count(*)=1 from public.ledger_entries where business_id=v_bc.business_id), 'Retry has exactly one financial entry';
  assert (select snapshot->'customers'->0->>'phone' is null from private.local_notebook_imports
    where notebook_id='a1900000-0000-0000-0000-000000000002'), 'Receipt contains no raw phone';
end $$;

-- A second notebook must reuse the global identity, not create an orphan.
select set_config('test.second',jsonb_set(jsonb_set(current_setting('test.notebook')::jsonb,
  '{id}','"a1900000-0000-0000-0000-000000000005"'),'{entries}','[]')::text,true);
set local role service_role;
select set_config('test.second_token',public.service_prepare_local_notebook_import(
  'a1900000-0000-0000-0000-000000000001',current_setting('test.second')::jsonb,
  current_setting('test.contacts')::jsonb)::text,true);
set local role authenticated;
select set_config('test.second_result',public.import_prepared_local_notebook(current_setting('test.second_token')::uuid)::text,true);
select set_config('request.jwt.claim.sub','a1900000-0000-0000-0000-000000000099',true);
do $$ begin
  begin
    perform public.import_prepared_local_notebook(current_setting('test.token')::uuid);
    raise exception 'Foreign user could consume preparation';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  assert (select count(distinct customer_id)=1 from public.business_customers
    where business_id in ((current_setting('test.result')::jsonb->>'business_id')::uuid,
      (current_setting('test.second_result')::jsonb->>'business_id')::uuid)), 'Existing phone identity reused';
end $$;

-- Invalid financial data rolls back contact resolution, business and clients.
select set_config('test.invalid',jsonb_set(jsonb_set(jsonb_set(current_setting('test.notebook')::jsonb,
  '{id}','"a1900000-0000-0000-0000-000000000006"'),'{customers,0,phone_hash}',to_jsonb(repeat('b',64))),
  '{entries,0,minor}','0')::text,true);
select set_config('test.invalid_contacts',jsonb_set(current_setting('test.contacts')::jsonb,
  '{a1900000-0000-0000-0000-000000000003,phone_hash}',to_jsonb(repeat('b',64)))::text,true);
set local role service_role;
select set_config('test.invalid_token',public.service_prepare_local_notebook_import(
  'a1900000-0000-0000-0000-000000000001',current_setting('test.invalid')::jsonb,
  current_setting('test.invalid_contacts')::jsonb)::text,true);
set local role authenticated;
select set_config('request.jwt.claim.sub','a1900000-0000-0000-0000-000000000001',true);
do $$ begin
  begin
    perform public.import_prepared_local_notebook(current_setting('test.invalid_token')::uuid);
    raise exception 'Invalid ledger accepted';
  exception when raise_exception then
    if sqlerrm <> 'Amount out of range' then raise; end if;
  end;
end $$;
reset role;
do $$ begin
  assert not exists(select 1 from private.customer_contacts where phone_hash=repeat('b',64)), 'No orphan phone after failed import';
  assert not exists(select 1 from private.local_notebook_imports where notebook_id='a1900000-0000-0000-0000-000000000006'), 'No failed receipt persisted';
end $$;
-- Simulate a v3 upload whose HTTP response was lost, then retry through v4.
select set_config('test.legacy',jsonb_set(jsonb_set(jsonb_set(current_setting('test.notebook')::jsonb,
  '{id}','"a1900000-0000-0000-0000-000000000007"'),'{customers,0,phone_hash}',to_jsonb(repeat('c',64))),
  '{entries}','[]')::text,true);
select set_config('test.legacy_original',(current_setting('test.legacy')::jsonb || jsonb_build_object(
  'customers',jsonb_build_array(((current_setting('test.legacy')::jsonb->'customers'->0)-'phone_hash') ||
    '{"phone":"777123456"}'::jsonb)))::text,true);
select set_config('test.legacy_contacts',jsonb_set(current_setting('test.contacts')::jsonb,
  '{a1900000-0000-0000-0000-000000000003,phone_hash}',to_jsonb(repeat('c',64)))::text,true);
select set_config('test.legacy_result',private.import_local_notebook_with_contacts(
  jsonb_set(current_setting('test.legacy')::jsonb,'{customers}',jsonb_build_array(
    (current_setting('test.legacy')::jsonb->'customers'->0)-'phone_hash')),'{}')::text,true);
update private.local_notebook_imports set
  result=result-'customer_map'-'phone_count',
  snapshot=jsonb_build_object('id',snapshot->'id','name',snapshot->'name','currency',snapshot->'currency',
    'customers',current_setting('test.legacy_original')::jsonb->'customers','entries',snapshot->'entries')
where notebook_id='a1900000-0000-0000-0000-000000000007';
set local role service_role;
select set_config('test.legacy_token',public.service_prepare_local_notebook_import(
  'a1900000-0000-0000-0000-000000000001',current_setting('test.legacy')::jsonb,
  current_setting('test.legacy_contacts')::jsonb,current_setting('test.legacy_original')::jsonb)::text,true);
set local role authenticated;
select set_config('test.legacy_retried',public.import_prepared_local_notebook(current_setting('test.legacy_token')::uuid)::text,true);
do $$ begin
  assert current_setting('test.legacy_result')::jsonb->>'business_id' = current_setting('test.legacy_retried')::jsonb->>'business_id', 'Legacy retry retains original business';
  assert (current_setting('test.legacy_retried')::jsonb->>'phone_count')::int=1, 'Legacy retry repairs contact';
end $$;
reset role;
do $$ begin
  assert (select snapshot->'customers'->0->>'phone' is null from private.local_notebook_imports
    where notebook_id='a1900000-0000-0000-0000-000000000007'), 'Legacy receipt now contains no raw phone';
end $$;
rollback;
select 'PASS: encrypted contacts, notes, identity reuse, retry, account isolation and atomic rollback' as result;

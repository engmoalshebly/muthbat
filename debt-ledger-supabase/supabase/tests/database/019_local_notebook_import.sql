begin;
select plan(5);
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','93811111-1111-1111-1111-111111111111','authenticated','authenticated','local-import@example.test','unused',now(),'{}','{"display_name":"Import merchant","user_type":"merchant"}',now(),now());
set local role authenticated;
select set_config('request.jwt.claim.sub','93811111-1111-1111-1111-111111111111',true);
select set_config('test.notebook',jsonb_build_object(
  'version',1,'id','93822222-2222-2222-2222-222222222222','owner_id','93811111-1111-1111-1111-111111111111','name','Imported shop','currency','YER',
  'customers',jsonb_build_array(jsonb_build_object('id','93833333-3333-3333-3333-333333333333','name','Local customer')),
  'entries',jsonb_build_array(
    jsonb_build_object('id','93844444-4444-4444-4444-444444444444','customer_id','93833333-3333-3333-3333-333333333333','type','debt','direction','debit','minor',1000000,'description','Local debt','occurred_at',now()),
    jsonb_build_object('id','93855555-5555-5555-5555-555555555555','customer_id','93833333-3333-3333-3333-333333333333','type','payment','direction','credit','minor',200000,'description','Local payment','occurred_at',now()),
    jsonb_build_object('id','93866666-6666-6666-6666-666666666666','customer_id','93833333-3333-3333-3333-333333333333','type','discount','direction','credit','minor',100000,'description','Local discount','occurred_at',now()),
    jsonb_build_object('id','93877777-7777-7777-7777-777777777777','customer_id','93833333-3333-3333-3333-333333333333','type','reversal','direction','debit','minor',200000,'description','Reverse payment','occurred_at',now(),'reverses','93855555-5555-5555-5555-555555555555')
  ))::text,true);
select set_config('test.import_result',public.import_local_notebook(current_setting('test.notebook')::jsonb)::text,true);
select is((current_setting('test.import_result')::jsonb->>'entry_count')::int,4,'Imports all financial entry types');
select is(public.import_local_notebook(current_setting('test.notebook')::jsonb)::text,current_setting('test.import_result'),'Retry returns same result');
select is((select count(*)::int from public.ledger_entries where business_id=(current_setting('test.import_result')::jsonb->>'business_id')::uuid),4,'Retry does not duplicate entries');
select is((select sum(case when direction='debit' then amount else -amount end) from public.ledger_entries where business_id=(current_setting('test.import_result')::jsonb->>'business_id')::uuid),90::numeric,'Imported net balance includes reversal correctly');
select throws_ok($$select public.import_local_notebook(current_setting('test.notebook')::jsonb || '{"name":"Changed notebook"}'::jsonb)$$,'22023','Imported snapshot cannot be changed','Cannot mutate a completed snapshot');
select * from finish();
rollback;

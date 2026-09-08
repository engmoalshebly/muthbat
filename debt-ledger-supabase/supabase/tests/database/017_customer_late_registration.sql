begin;
select plan(7);
select set_config('test.late_id',(select customer_id::text from public.service_resolve_customer_phone(repeat('c',64),decode('abcd','hex'),'1234',1::smallint)),true);
select is((select customer_id::text from public.service_resolve_customer_phone(repeat('c',64),decode('abcd','hex'),'1234',1::smallint)),current_setting('test.late_id'),'Directory retry resolves the same identity');
select is((select count(*)::int from private.customer_contacts where phone_hash=repeat('c',64)),1,'Only one contact exists');
insert into auth.users(instance_id,id,aud,role,phone,phone_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','91811111-1111-1111-1111-111111111111','authenticated','authenticated','967700001234',now(),'{}','{"display_name":"Late registration test"}',now(),now());
select set_config('test.empty_id',(select id::text from public.customers where user_id='91811111-1111-1111-1111-111111111111'),true);
select is(public.service_claim_customer_phone('91811111-1111-1111-1111-111111111111',repeat('c',64),decode('abcd','hex'),'1234',1::smallint)::text,current_setting('test.late_id'),'Registration adopts old identity');
select is((select status::text from public.customers where id=current_setting('test.empty_id')::uuid),'merged','Unused identity is retained as merged, not deleted');
select is(public.service_claim_customer_phone('91811111-1111-1111-1111-111111111111',repeat('c',64),decode('abcd','hex'),'1234',1::smallint)::text,current_setting('test.late_id'),'Claim retry is idempotent');
select ok(not has_function_privilege('authenticated','public.service_resolve_customer_phone(text,bytea,text,smallint)','execute'),'Client cannot enumerate phone identities');
update auth.users set raw_app_meta_data='{"phone_verification_bypassed":true}' where id='91811111-1111-1111-1111-111111111111';
select throws_ok($$select public.service_claim_customer_phone('91811111-1111-1111-1111-111111111111',repeat('c',64),decode('abcd','hex'),'1234',1::smallint)$$,'42501','verified_phone_required','Bypassed verification cannot claim a phone');
select * from finish();
rollback;

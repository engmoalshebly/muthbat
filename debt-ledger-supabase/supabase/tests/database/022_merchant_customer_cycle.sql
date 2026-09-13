begin;
select plan(8);
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
('00000000-0000-0000-0000-000000000000','94811111-1111-1111-1111-111111111111','authenticated','authenticated','cycle-owner@example.test','unused',now(),'{}','{"display_name":"Owner"}',now(),now()),
('00000000-0000-0000-0000-000000000000','94822222-2222-2222-2222-222222222222','authenticated','authenticated','cycle-customer@example.test','unused',now(),'{}','{"display_name":"Customer"}',now(),now()),
('00000000-0000-0000-0000-000000000000','94833333-3333-3333-3333-333333333333','authenticated','authenticated','cycle-other@example.test','unused',now(),'{}','{"display_name":"Other"}',now(),now());
select set_config('test.customer',(select id::text from public.customers where user_id='94822222-2222-2222-2222-222222222222'),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','94811111-1111-1111-1111-111111111111',true);
select set_config('test.business',public.create_business('Cycle shop','retail','YER')::text,true);
select set_config('test.bc',public.add_business_customer(current_setting('test.business')::uuid,current_setting('test.customer')::uuid,'Old name',500)::text,true);
select lives_ok($$select public.update_business_customer_profile(current_setting('test.bc')::uuid,'New name','Private note',700::numeric,30::smallint)$$,'Owner edits customer');
select is((select local_display_name from public.business_customers where id=current_setting('test.bc')::uuid),'New name','Edited name persisted');
select set_config('test.link',public.request_customer_link(current_setting('test.bc')::uuid)::text,true);
select set_config('request.jwt.claim.sub','94822222-2222-2222-2222-222222222222',true);
select is((select count(*)::int from public.customer_business_summary where business_id=current_setting('test.business')::uuid),0,'Customer sees no shop before accepting link');
select lives_ok($$select public.respond_link_request(current_setting('test.link')::uuid,true)$$,'Customer accepts link');
select is((select count(*)::int from public.entry_confirmations),0,'Accepting link confirms no debts');
select set_config('request.jwt.claim.sub','94833333-3333-3333-3333-333333333333',true);
select throws_ok($$select public.update_business_customer_profile(current_setting('test.bc')::uuid,'Attack',null,null,null)$$,'42501','Owner permission required','Other user cannot edit customer');
select set_config('request.jwt.claim.sub','94811111-1111-1111-1111-111111111111',true);
select lives_ok($$select public.archive_business_customer(current_setting('test.bc')::uuid)$$,'Owner archives without deleting ledger relation');
select is((select is_archived from public.business_customers where id=current_setting('test.bc')::uuid),true,'Customer is archived');
select * from finish();
rollback;

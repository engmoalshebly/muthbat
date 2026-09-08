begin;
select plan(4);
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','92811111-1111-1111-1111-111111111111','authenticated','authenticated','outbox-merchant@example.test','unused',now(),'{}','{"display_name":"Outbox merchant"}',now(),now()),
('00000000-0000-0000-0000-000000000000','92822222-2222-2222-2222-222222222222','authenticated','authenticated','outbox-customer@example.test','unused',now(),'{}','{"display_name":"Outbox customer"}',now(),now());
select set_config('test.outbox_customer',(select id::text from public.customers where user_id='92822222-2222-2222-2222-222222222222'),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','92811111-1111-1111-1111-111111111111',true);
select set_config('test.outbox_business',public.create_business('Outbox shop','retail','YER')::text,true);
select set_config('test.outbox_bc',public.add_business_customer(current_setting('test.outbox_business')::uuid,current_setting('test.outbox_customer')::uuid,'Customer',500)::text,true);
select set_config('test.outbox_link',public.request_customer_link(current_setting('test.outbox_bc')::uuid)::text,true);
select set_config('request.jwt.claim.sub','92822222-2222-2222-2222-222222222222',true);
select is(public.submit_customer_action('92833333-3333-3333-3333-333333333333',jsonb_build_object('kind','link','target_id',current_setting('test.outbox_link'),'accept',true))->>'completed','true','Queued consent completes');
select is(public.submit_customer_action('92833333-3333-3333-3333-333333333333',jsonb_build_object('kind','link','target_id',current_setting('test.outbox_link'),'accept',true))->>'replayed','true','Lost response retry returns receipt');
select throws_ok($$select public.submit_customer_action('92833333-3333-3333-3333-333333333333',jsonb_build_object('kind','link','target_id',current_setting('test.outbox_link'),'accept',false))$$,'22023','Request payload mismatch','Same request cannot change consent');
select ok(not has_function_privilege('anon','public.submit_customer_action(uuid,jsonb)','execute'),'Anonymous cannot submit queued actions');
select * from finish();
rollback;

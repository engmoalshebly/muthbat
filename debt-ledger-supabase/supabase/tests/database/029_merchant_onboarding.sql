begin;
select plan(5);
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','b4111111-1111-4111-8111-111111111111','authenticated','authenticated','merchant-onboarding@example.test','unused',now(),'{}','{}',now(),now());
set local role authenticated;
select set_config('request.jwt.claim.sub','b4111111-1111-4111-8111-111111111111',true);
select set_config('test.profile','{"name":"Test store","business_type":"retail","currency_code":"YER","contact_phone":"+967777123456"}',true);
select set_config('test.business',public.create_business_idempotent('b4222222-2222-4222-8222-222222222222',current_setting('test.profile')::jsonb)::text,true);
select is(public.create_business_idempotent('b4222222-2222-4222-8222-222222222222',current_setting('test.profile')::jsonb)::text,current_setting('test.business'),'lost response retry returns original business');
select is((select count(*) from public.businesses where owner_user_id=auth.uid()),1::bigint,'one business created');
select is((select contact_phone_display from public.businesses where id=current_setting('test.business')::uuid),'+967777123456','phone committed with business');
select is((select role::text from public.business_members where business_id=current_setting('test.business')::uuid and user_id=auth.uid()),'owner','owner membership committed');
select throws_ok($$select public.create_business_idempotent('b4222222-2222-4222-8222-222222222222','{"name":"Changed"}'::jsonb)$$,'22023','Request payload cannot change','receipt rejects changed retry');
select * from finish();
rollback;

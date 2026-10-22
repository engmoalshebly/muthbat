-- Disposable migrated database only; all fixtures are rolled back.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','a1910000-0000-0000-0000-000000000001','authenticated','authenticated','directory-test@example.test','unused',now(),'{}','{"display_name":"Directory test","user_type":"merchant"}',now(),now());
set local role authenticated;
select set_config('request.jwt.claim.sub','a1910000-0000-0000-0000-000000000001',true);
select set_config('test.business',private.command_create_business('Directory test','grocery','YER','YE',null,null,'{}')::text,true);
select set_config('test.payload',jsonb_build_object('businessId',current_setting('test.business'),'localDisplayName','Test customer','localNote','Preserved note','creditLimit',null,'defaultDueDays',null,'requestLink',false)::text,true);
set local role service_role;
select public.service_prepare_customer_directory('a1910000-0000-0000-0000-000000000001','a1910000-0000-0000-0000-000000000002',current_setting('test.payload')::jsonb,'{}');
set local role authenticated;
select set_config('test.result',public.complete_customer_directory('a1910000-0000-0000-0000-000000000002')::text,true);
do $$ begin
  assert public.complete_customer_directory('a1910000-0000-0000-0000-000000000002')=current_setting('test.result')::jsonb,'Lost response retry returns identical receipt';
  begin
    perform public.service_prepare_customer_directory(auth.uid(),'a1910000-0000-0000-0000-000000000003','{}','{}');
    raise exception 'Untrusted preparation accepted';
  exception when insufficient_privilege then null; end;
end $$;
set local role service_role;
do $$ begin
  begin
    perform public.service_prepare_customer_directory('a1910000-0000-0000-0000-000000000001','a1910000-0000-0000-0000-000000000002',current_setting('test.payload')::jsonb||'{"localDisplayName":"Changed"}','{}');
    raise exception 'Changed payload accepted';
  exception when invalid_parameter_value then null; end;
end $$;
select public.service_prepare_customer_directory('a1910000-0000-0000-0000-000000000001','a1910000-0000-0000-0000-000000000004',current_setting('test.payload')::jsonb||'{"localDisplayName":"Phone customer"}',jsonb_build_object('phone_hash',repeat('c',64),'phone_ciphertext','\x01020304','phone_last4','1234','key_version',1));
set local role authenticated;
select set_config('test.phone_result',public.complete_customer_directory('a1910000-0000-0000-0000-000000000004')::text,true);
select set_config('request.jwt.claim.sub','a1910000-0000-0000-0000-000000000099',true);
do $$ begin
  begin
    perform public.complete_customer_directory('a1910000-0000-0000-0000-000000000002');
    raise exception 'Other account consumed receipt';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Fail after identity/contact creation to prove the whole command rolls back.
create function pg_temp.fail_directory_note() returns trigger language plpgsql as $$
begin
  if new.local_note='Force rollback' then raise exception 'forced_directory_failure'; end if;
  return new;
end $$;
create trigger test_directory_failure before update on public.business_customers
for each row execute function pg_temp.fail_directory_note();
set local role service_role;
select public.service_prepare_customer_directory('a1910000-0000-0000-0000-000000000001','a1910000-0000-0000-0000-000000000005',current_setting('test.payload')::jsonb||'{"localNote":"Force rollback"}',jsonb_build_object('phone_hash',repeat('d',64),'phone_ciphertext','\x01020304','phone_last4','5678','key_version',1));
set local role authenticated;
select set_config('request.jwt.claim.sub','a1910000-0000-0000-0000-000000000001',true);
do $$ begin
  begin
    perform public.complete_customer_directory('a1910000-0000-0000-0000-000000000005');
    raise exception 'Failure was not raised';
  exception when raise_exception then
    if sqlerrm <> 'forced_directory_failure' then raise; end if;
  end;
end $$;
reset role;
do $$ begin
  assert not exists(select 1 from private.customer_contacts where phone_hash=repeat('d',64)),'No orphan contact after failed transaction';
  assert (select result is null from private.customer_directory_receipts where request_id='a1910000-0000-0000-0000-000000000005'),'Failed request has no success receipt';
  assert (select count(*)=2 from public.business_customers where business_id=current_setting('test.business')::uuid),'Exactly two customers despite retry';
  assert (select local_note='Preserved note' from public.business_customers where id=(current_setting('test.result')::jsonb->>'businessCustomerId')::uuid),'Note stored atomically';
  assert exists(select 1 from private.customer_contacts c join public.business_customers b on b.customer_id=c.customer_id where b.id=(current_setting('test.phone_result')::jsonb->>'businessCustomerId')::uuid and c.phone_hash=repeat('c',64) and c.phone_ciphertext='\x01020304'::bytea),'Encrypted phone attached';
end $$;
rollback;

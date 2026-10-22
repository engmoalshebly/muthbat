-- Disposable migrated database; all fixtures rolled back.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','a1920000-0000-0000-0000-000000000001','authenticated','authenticated','contacts-test@example.test','unused',now(),'{}','{"display_name":"Contact test","user_type":"merchant"}',now(),now());
insert into auth.sessions(id,user_id) values('a1920000-0000-0000-0000-000000000002','a1920000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.sub','a1920000-0000-0000-0000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"a1920000-0000-0000-0000-000000000001","session_id":"a1920000-0000-0000-0000-000000000002"}',true);
set local role authenticated;
select set_config('test.business',private.command_create_business('Contact test','grocery','YER','YE',null,null,'{}')::text,true);
select set_config('test.customer',private.command_create_business_customer_direct(current_setting('test.business')::uuid,'Contact test',null,null)::text,true);
select public.register_customer_contact_device('a1920000-0000-0000-0000-000000000003','android');
do $$ begin
  begin
    perform public.service_read_customer_contacts(auth.uid(),'a1920000-0000-0000-0000-000000000002','a1920000-0000-0000-0000-000000000003',current_setting('test.business')::uuid,array[current_setting('test.customer')::uuid]);
    raise exception 'Direct contact read accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
insert into private.customer_contacts(customer_id,phone_hash,phone_ciphertext,phone_last4,encryption_key_version)
select customer_id,repeat('e',64),'\x01020304'::bytea,'3456',1 from public.business_customers where id=current_setting('test.customer')::uuid;
set local role service_role;
do $$ begin
  assert (select count(*)=1 from public.service_read_customer_contacts('a1920000-0000-0000-0000-000000000001','a1920000-0000-0000-0000-000000000002','a1920000-0000-0000-0000-000000000003',current_setting('test.business')::uuid,array[current_setting('test.customer')::uuid])),'Authorized session/device/member can read';
  begin
    perform public.service_read_customer_contacts('a1920000-0000-0000-0000-000000000001','a1920000-0000-0000-0000-000000000099','a1920000-0000-0000-0000-000000000003',current_setting('test.business')::uuid,array[current_setting('test.customer')::uuid]);
    raise exception 'Foreign session accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.service_read_customer_contacts('a1920000-0000-0000-0000-000000000001','a1920000-0000-0000-0000-000000000002','a1920000-0000-0000-0000-000000000003','a1920000-0000-0000-0000-000000000099',array[current_setting('test.customer')::uuid]);
    raise exception 'Other business accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
update public.device_installations set revoked_at=now() where device_id='a1920000-0000-0000-0000-000000000003';
set local role authenticated;
do $$ begin
  begin
    perform public.register_customer_contact_device('a1920000-0000-0000-0000-000000000003','android');
    raise exception 'Revoked device reactivated';
  exception when insufficient_privilege then null; end;
  begin
    update public.device_installations set revoked_at=null where device_id='a1920000-0000-0000-0000-000000000003';
    raise exception 'Client removed revocation';
  exception when insufficient_privilege then null; end;
end $$;
set local role service_role;
do $$ begin
  begin
    perform public.service_read_customer_contacts('a1920000-0000-0000-0000-000000000001','a1920000-0000-0000-0000-000000000002','a1920000-0000-0000-0000-000000000003',current_setting('test.business')::uuid,array[current_setting('test.customer')::uuid]);
    raise exception 'Revoked device read contacts';
  exception when insufficient_privilege then null; end;
end $$;
rollback;

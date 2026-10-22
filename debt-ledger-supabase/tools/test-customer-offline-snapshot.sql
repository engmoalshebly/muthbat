begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','a1960000-0000-0000-0000-000000000001','authenticated','authenticated','snapshot-test@example.test','unused',now(),'{}','{"display_name":"Snapshot test","user_type":"merchant"}',now(),now());
select set_config('request.jwt.claim.sub','a1960000-0000-0000-0000-000000000001',true);
set local role authenticated;
select set_config('test.business',private.command_create_business('Snapshot test','grocery','YER','YE',null,null,'{}')::text,true);
select set_config('test.customer',private.command_create_business_customer_direct(current_setting('test.business')::uuid,'Original customer',null,null)::text,true);
select set_config('test.entry',public.create_ledger_entry(p_business_customer_id:=current_setting('test.customer')::uuid,p_entry_type:='debt',p_amount:=100,p_description:='Test debt',p_client_request_id:='a1960000-0000-0000-0000-000000000002')::text,true);
select set_config('test.snapshot',public.begin_merchant_sync_snapshot(p_business_id:=current_setting('test.business')::uuid,p_device_id:='a1960000-0000-0000-0000-000000000010')::text,true);
select public.create_ledger_entry(p_business_customer_id:=current_setting('test.customer')::uuid,p_entry_type:='payment',p_amount:=20,p_description:='Later payment',p_client_request_id:='a1960000-0000-0000-0000-000000000003');
select set_config('test.mutation',public.mutate_customer_profile('a1960000-0000-0000-0000-000000000004',current_setting('test.customer')::uuid,'update','{"display_name":"Updated customer","note":"Local note"}')::text,true);
do $$ declare snap uuid:=(current_setting('test.snapshot')::jsonb->>'snapshot_id')::uuid; begin
  assert (select count(*)=1 from public.read_merchant_sync_snapshot(snap) where kind='entry'),'Snapshot excludes later entry';
  assert (select (payload->>'current_balance')::numeric=100 from public.read_merchant_sync_snapshot(snap) where kind='balance'),'Snapshot balance and ledger agree';
  assert (select payload->>'local_display_name'='Original customer' from public.read_merchant_sync_snapshot(snap) where kind='customer'),'Snapshot profile remains immutable';
  assert (select count(*)=1 from public.read_merchant_sync_snapshot(snap,0,1)),'Page size respected';
  assert public.mutate_customer_profile('a1960000-0000-0000-0000-000000000004',current_setting('test.customer')::uuid,'update','{"display_name":"Updated customer","note":"Local note"}')=current_setting('test.mutation')::jsonb,'Stable profile receipt';
  begin
    perform public.mutate_customer_profile('a1960000-0000-0000-0000-000000000004',current_setting('test.customer')::uuid,'archive','{}');
    raise exception 'Changed receipt payload accepted';
  exception when invalid_parameter_value then null; end;
end $$;
select public.mutate_customer_profile('a1960000-0000-0000-0000-000000000005',current_setting('test.customer')::uuid,'archive','{}');
select set_config('test.second',public.begin_merchant_sync_snapshot(p_business_id:=current_setting('test.business')::uuid,p_device_id:='a1960000-0000-0000-0000-000000000010')::text,true);
do $$ begin
  assert (select (payload->>'is_archived')::boolean from public.read_merchant_sync_snapshot((current_setting('test.second')::jsonb->>'snapshot_id')::uuid) where kind='customer'),'Remote archive is included';
  assert (select (payload->>'current_balance')::numeric=80 from public.read_merchant_sync_snapshot((current_setting('test.second')::jsonb->>'snapshot_id')::uuid) where kind='balance'),'New snapshot includes later payment';
end $$;
select set_config('request.jwt.claim.sub','a1960000-0000-0000-0000-000000000099',true);
do $$ begin
  begin
    perform public.read_merchant_sync_snapshot((current_setting('test.snapshot')::jsonb->>'snapshot_id')::uuid);
    raise exception 'Foreign user read snapshot';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','a1960000-0000-0000-0000-000000000001',true);
select public.release_merchant_sync_snapshot((current_setting('test.second')::jsonb->>'snapshot_id')::uuid);
select set_config('test.empty',public.begin_merchant_sync_snapshot(p_business_id:=current_setting('test.business')::uuid,p_device_id:='a1960000-0000-0000-0000-000000000010',p_previous_snapshot_id:=(current_setting('test.second')::jsonb->>'snapshot_id')::uuid)::text,true);
do $$ begin
  assert not exists(select 1 from public.read_merchant_sync_snapshot((current_setting('test.empty')::jsonb->>'snapshot_id')::uuid) where kind='entry'),'Acknowledged immutable entries are not resent';
  assert not exists(select 1 from public.read_merchant_sync_snapshot((current_setting('test.empty')::jsonb->>'snapshot_id')::uuid) where kind='state'),'Unchanged acknowledged states are not resent';
end $$;
reset role;
update public.ledger_entry_state set confirmation_status='confirmed' where entry_id=current_setting('test.entry')::uuid;
set local role authenticated;
select set_config('test.changed',public.begin_merchant_sync_snapshot(p_business_id:=current_setting('test.business')::uuid,p_device_id:='a1960000-0000-0000-0000-000000000010',p_previous_snapshot_id:=(current_setting('test.second')::jsonb->>'snapshot_id')::uuid,p_cursor:=now()+interval '1 year')::text,true);
do $$ begin
  assert exists(select 1 from public.read_merchant_sync_snapshot((current_setting('test.changed')::jsonb->>'snapshot_id')::uuid) where kind='state' and payload->>'confirmation_status'='confirmed'),'Changed state arrives independently of creation cursor';
end $$;
select set_config('test.restored',public.begin_merchant_sync_snapshot(p_business_id:=current_setting('test.business')::uuid,p_device_id:='a1960000-0000-0000-0000-000000000010',p_previous_snapshot_id:=null)::text,true);
do $$ begin
  assert (select count(*)=2 from public.read_merchant_sync_snapshot((current_setting('test.restored')::jsonb->>'snapshot_id')::uuid) where kind='entry'),'Restored cache cannot skip newer acknowledgments';
end $$;
rollback;

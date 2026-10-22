-- Standalone assertions; all generated data is rolled back.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id::uuid,'authenticated','authenticated',email,'unused',now(),'{}','{}',now(),now()
from (values ('c4111111-1111-4111-8111-111111111111','snapshot-merchant@example.test'),('c4222222-2222-4222-8222-222222222222','snapshot-customer@example.test')) t(id,email);
select set_config('request.jwt.claim.sub','c4111111-1111-4111-8111-111111111111',true);
insert into public.businesses(owner_user_id,name,business_type,currency_code,city)
select auth.uid(),'Snapshot shop '||i,'retail','YER',case when i<=1001 then 'linked' else 'pending' end from generate_series(1,2002) i;
insert into public.business_members(business_id,user_id,role)
select id,auth.uid(),'owner' from public.businesses where owner_user_id=auth.uid();
insert into public.business_customers(business_id,customer_id,local_display_name,link_status,created_by_user_id)
select b.id,c.id,'Test customer',b.city::public.customer_link_status,auth.uid() from public.businesses b cross join public.customers c
where b.owner_user_id=auth.uid() and c.user_id='c4222222-2222-4222-8222-222222222222';
insert into public.customer_link_requests(business_customer_id,requested_by_user_id,target_customer_id)
select id,auth.uid(),customer_id from public.business_customers where created_by_user_id=auth.uid() and link_status='pending';
select set_config('test.bc',(select id::text from public.business_customers where created_by_user_id=auth.uid() and link_status='linked' limit 1),true);
insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,client_request_id,created_by_user_id)
select bc.business_id,bc.id,bc.customer_id,'debt','debit',1,'YER','Test debt',gen_random_uuid(),auth.uid()
from public.business_customers bc cross join generate_series(1,1001) i where bc.id=current_setting('test.bc')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub','c4222222-2222-4222-8222-222222222222',true);
select set_config('test.snapshot',(public.begin_customer_read_snapshot()->>'snapshot_id'),true);
do $$ declare cursor_value bigint:=0; n bigint; page_count int; shops int:=0; requests int:=0; entries int:=0; begin
 loop
  select count(*),max(ordinal),count(*) filter(where kind='summary'),count(*) filter(where kind='request'),count(*) filter(where kind='entry')
    into page_count,n,shops,requests,entries from public.read_customer_read_snapshot(current_setting('test.snapshot')::uuid,cursor_value,250);
  exit when page_count=0;
  cursor_value:=n;
 end loop;
 if cursor_value<>3004 then raise exception 'Snapshot truncated: %',cursor_value; end if;
end $$;
-- Write another debt after the snapshot; it must not leak into the old pages.
reset role;
select set_config('request.jwt.claim.sub','c4111111-1111-4111-8111-111111111111',true);
insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,client_request_id,created_by_user_id)
select business_id,id,customer_id,'debt','debit',7,'YER','Later debt',gen_random_uuid(),auth.uid() from public.business_customers where id=current_setting('test.bc')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub','c4222222-2222-4222-8222-222222222222',true);
do $$ declare s jsonb; total bigint; begin
 select count(*) into total from public.read_customer_read_snapshot(current_setting('test.snapshot')::uuid,3000,250);
 if total<>4 then raise exception 'Frozen snapshot changed'; end if;
 s:=public.begin_customer_read_snapshot('ledger',current_setting('test.bc')::uuid,'YER');
 if (s->>'item_count')::int<>1004 then raise exception 'Full ledger incomplete: %',s; end if;
 perform public.release_customer_read_snapshot((s->>'snapshot_id')::uuid);
end $$;
select set_config('request.jwt.claim.sub','c4111111-1111-4111-8111-111111111111',true);
do $$ begin
 begin perform * from public.read_customer_read_snapshot(current_setting('test.snapshot')::uuid); raise exception 'Other user read snapshot'; exception when insufficient_privilege then null; end;
end $$;
reset role;
update public.business_customers set is_archived=true where id=current_setting('test.bc')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub','c4222222-2222-4222-8222-222222222222',true);
do $$ begin
 begin perform * from public.read_customer_read_snapshot(current_setting('test.snapshot')::uuid); raise exception 'Archived account remained readable'; exception when insufficient_privilege then null; end;
end $$;
rollback;

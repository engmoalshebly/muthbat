-- Financial entries count immediately, without customer acknowledgments.
-- Run against the migrated database; generated fixtures always roll back.
begin;
select plan(1);
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id::uuid,'authenticated','authenticated',email,'unused',now(),'{}','{}',now(),now()
from (values
 ('c5111111-1111-4111-8111-111111111111','recorded-merchant@example.test'),
 ('c5222222-2222-4222-8222-222222222222','recorded-customer@example.test'),
 ('c5333333-3333-4333-8333-333333333333','recorded-outsider@example.test')) t(id,email);
select set_config('request.jwt.claim.sub','c5111111-1111-4111-8111-111111111111',true);
insert into public.businesses(owner_user_id,name,business_type,currency_code)
values(auth.uid(),'Recorded entries test','retail','YER');
insert into public.business_members(business_id,user_id,role)
select id,auth.uid(),'owner' from public.businesses where owner_user_id=auth.uid();
insert into public.business_customers(business_id,customer_id,local_display_name,link_status,created_by_user_id)
select b.id,c.id,'Test customer','linked',auth.uid() from public.businesses b cross join public.customers c
where b.owner_user_id=auth.uid() and c.user_id='c5222222-2222-4222-8222-222222222222';
select set_config('test.bc',(select id::text from public.business_customers where created_by_user_id=auth.uid()),true);
insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,client_request_id,created_by_user_id)
select business_id,id,customer_id,'debt','debit',100,'YER','Debt',gen_random_uuid(),auth.uid()
from public.business_customers where id=current_setting('test.bc')::uuid;
insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,client_request_id,created_by_user_id)
select business_id,id,customer_id,'payment','credit',30,'YER','Payment',gen_random_uuid(),auth.uid()
from public.business_customers where id=current_setting('test.bc')::uuid;
select set_config('test.debt',(select id::text from public.ledger_entries where business_customer_id=current_setting('test.bc')::uuid and entry_type='debt'),true);
select set_config('test.payment',(select id::text from public.ledger_entries where business_customer_id=current_setting('test.bc')::uuid and entry_type='payment'),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','c5222222-2222-4222-8222-222222222222',true);
do $$ declare v_id uuid; v_replay uuid; begin
 if (select current_balance from public.customer_business_summary where business_customer_id=current_setting('test.bc')::uuid and currency_code='YER')<>70 then
   raise exception 'Entries did not count before confirmation';
 end if;
 if exists(select 1 from public.entry_confirmations where entry_id=current_setting('test.debt')::uuid) then
   raise exception 'Registration fabricated customer consent';
 end if;
 -- A previous explicit acknowledgment must not waive the right to object later.
 perform public.confirm_ledger_entry(current_setting('test.debt')::uuid);
 v_id:=public.open_dispute(current_setting('test.debt')::uuid,'wrong_amount','Review the recorded debt','c5444444-4444-4444-8444-444444444444');
 v_replay:=public.open_dispute(current_setting('test.debt')::uuid,'wrong_amount','Review the recorded debt','c5444444-4444-4444-8444-444444444444');
 if v_id<>v_replay then raise exception 'Dispute replay created another dispute'; end if;
 if (select current_balance from public.customer_business_summary where business_customer_id=current_setting('test.bc')::uuid and currency_code='YER')<>70 then
   raise exception 'Dispute changed the recorded balance';
 end if;
 begin
   perform public.open_dispute(current_setting('test.debt')::uuid,'duplicate','Another dispute');
   raise exception 'Duplicate dispute was accepted';
 exception when raise_exception then
   if sqlerrm<>'An active dispute already exists' then raise; end if;
 end;
end $$;
select set_config('request.jwt.claim.sub','c5333333-3333-4333-8333-333333333333',true);
do $$ begin
 begin
   perform public.open_dispute(current_setting('test.payment')::uuid,'wrong_amount','Not my account');
   raise exception 'Another customer was allowed to dispute';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
update public.ledger_entry_state set is_reversed=true where entry_id=current_setting('test.payment')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub','c5222222-2222-4222-8222-222222222222',true);
do $$ begin
 begin
   perform public.open_dispute(current_setting('test.payment')::uuid,'wrong_amount','Reversed payment');
   raise exception 'Reversed entry allowed a dispute';
 exception when raise_exception then
   if sqlerrm<>'Cannot dispute a reversed entry' then raise; end if;
 end;
end $$;
select pass('Customer-recorded entries count immediately and disputes behave as expected');
select * from finish();
rollback;

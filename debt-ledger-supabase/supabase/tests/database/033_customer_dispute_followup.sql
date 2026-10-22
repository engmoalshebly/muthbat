-- Financial entries count immediately, without customer acknowledgments.
-- Run against the migrated database; generated fixtures always roll back.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id::uuid,'authenticated','authenticated',email,'unused',now(),'{}','{}',now(),now()
from (values
 ('c6111111-1111-4111-8111-111111111111','followup-merchant@example.test'),
 ('c6222222-2222-4222-8222-222222222222','followup-customer@example.test'),
 ('c6333333-3333-4333-8333-333333333333','followup-outsider@example.test')) t(id,email);
select set_config('request.jwt.claim.sub','c6111111-1111-4111-8111-111111111111',true);
insert into public.businesses(owner_user_id,name,business_type,currency_code)
values(auth.uid(),'Recorded entries test','retail','YER');
insert into public.business_members(business_id,user_id,role)
select id,auth.uid(),'owner' from public.businesses where owner_user_id=auth.uid();
insert into public.business_customers(business_id,customer_id,local_display_name,link_status,created_by_user_id)
select b.id,c.id,'Test customer','linked',auth.uid() from public.businesses b cross join public.customers c
where b.owner_user_id=auth.uid() and c.user_id='c6222222-2222-4222-8222-222222222222';
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
select set_config('request.jwt.claim.sub','c6222222-2222-4222-8222-222222222222',true);
select set_config('test.dispute',public.open_dispute(current_setting('test.debt')::uuid,'wrong_amount','المبلغ الصحيح أقل')::text,true);
do $$ declare item jsonb; begin
 select document into item from public.customer_disputes_page() where id=current_setting('test.dispute')::uuid;
 if item is null or item->>'status'<>'awaiting_merchant' or item->'entry'->>'currency_code'<>'YER' then
   raise exception 'Customer followup snapshot missing'; end if;
end $$;
select set_config('request.jwt.claim.sub','c6111111-1111-4111-8111-111111111111',true);
select public.add_dispute_message(current_setting('test.dispute')::uuid,'ما المبلغ الصحيح؟');
select set_config('request.jwt.claim.sub','c6222222-2222-4222-8222-222222222222',true);
select public.submit_customer_action('c6444444-4444-4444-8444-444444444444',
 jsonb_build_object('kind','dispute_reply','target_id',current_setting('test.dispute'),'message','الصحيح 80'));
select public.submit_customer_action('c6444444-4444-4444-8444-444444444444',
 jsonb_build_object('kind','dispute_reply','target_id',current_setting('test.dispute'),'message','الصحيح 80'));
do $$ declare item jsonb; begin
 select document into item from public.customer_disputes_page() where id=current_setting('test.dispute')::uuid;
 if item->>'status'<>'awaiting_merchant' or jsonb_array_length(item->'messages')<>2 then
   raise exception 'Reply duplication or missing merchant message'; end if;
end $$;
select set_config('request.jwt.claim.sub','c6333333-3333-4333-8333-333333333333',true);
do $$ begin
 if exists(select 1 from public.customer_disputes_page()) then raise exception 'Another customer read disputes'; end if;
 begin
   perform public.submit_customer_action(gen_random_uuid(),jsonb_build_object('kind','dispute_reply','target_id',current_setting('test.dispute'),'message','Intruder'));
   raise exception 'Another customer replied';
 exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','c6111111-1111-4111-8111-111111111111',true);
do $$ declare first uuid; replay uuid; begin
 first:=public.resolve_dispute(current_setting('test.dispute')::uuid,'partially_accepted','تم تصحيح المبلغ',80,'c6555555-5555-4555-8555-555555555555');
 replay:=public.resolve_dispute(current_setting('test.dispute')::uuid,'partially_accepted','تم تصحيح المبلغ',80,'c6555555-5555-4555-8555-555555555555');
 if first is distinct from replay or first is null then raise exception 'Resolution replay failed'; end if;
end $$;
select set_config('request.jwt.claim.sub','c6222222-2222-4222-8222-222222222222',true);
-- A delivered reply must replay successfully even after the dispute is closed.
select public.submit_customer_action('c6444444-4444-4444-8444-444444444444',
 jsonb_build_object('kind','dispute_reply','target_id',current_setting('test.dispute'),'message','الصحيح 80'));
do $$ declare item jsonb; begin
 select document into item from public.customer_disputes_page() where id=current_setting('test.dispute')::uuid;
 if item->>'status'<>'partially_accepted' or (item->>'corrected_amount')::numeric<>80 or item->>'resolution_note'<>'تم تصحيح المبلغ' then
   raise exception 'Resolution outcome not visible to customer'; end if;
 if (select current_balance from public.customer_business_summary where business_customer_id=current_setting('test.bc')::uuid and currency_code='YER')<>50 then
   raise exception 'Correction was applied more than once'; end if;
 begin
   perform public.submit_customer_action(gen_random_uuid(),jsonb_build_object('kind','dispute_reply','target_id',current_setting('test.dispute'),'message','Late reply'));
   raise exception 'Closed dispute accepted a new reply';
 exception when sqlstate '55000' then null; end;
end $$;
reset role;
do $$ begin
 if has_function_privilege('anon','public.customer_disputes_page(uuid,integer)','execute') then
   raise exception 'Anonymous dispute reader exposed'; end if;
end $$;
rollback;

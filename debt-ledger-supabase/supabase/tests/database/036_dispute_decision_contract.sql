-- Dispute decisions remain atomic, authorized and idempotent.
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


update public.businesses set additional_currencies=array['SAR'] where owner_user_id=auth.uid();
insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,client_request_id,created_by_user_id)
select bc.business_id,bc.id,bc.customer_id,t.kind::public.ledger_entry_type,t.direction::public.ledger_direction,t.amount,t.currency,t.description,gen_random_uuid(),auth.uid()
from public.business_customers bc cross join (values
 ('debt','debit',50,'YER','Cancel fixture'),('debt','debit',60,'YER','Reject fixture'),
 ('payment','credit',40,'SAR','Payment correction fixture')) t(kind,direction,amount,currency,description)
where bc.id=current_setting('test.bc')::uuid;
select set_config('test.cancel_entry',(select id::text from public.ledger_entries where description='Cancel fixture' and business_customer_id=current_setting('test.bc')::uuid),true);
select set_config('test.reject_entry',(select id::text from public.ledger_entries where description='Reject fixture' and business_customer_id=current_setting('test.bc')::uuid),true);
select set_config('test.sar_entry',(select id::text from public.ledger_entries where description='Payment correction fixture' and business_customer_id=current_setting('test.bc')::uuid),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','c6222222-2222-4222-8222-222222222222',true);
select set_config('test.dispute',public.open_dispute(current_setting('test.debt')::uuid,'wrong_amount','Amount is incorrect')::text,true);
select set_config('test.cancel',public.open_dispute(current_setting('test.cancel_entry')::uuid,'duplicate','Duplicate operation')::text,true);
select set_config('test.reject',public.open_dispute(current_setting('test.reject_entry')::uuid,'unknown_transaction','Unknown operation')::text,true);
select set_config('test.sar',public.open_dispute(current_setting('test.sar_entry')::uuid,'wrong_amount','Payment amount is incorrect')::text,true);
select set_config('request.jwt.claim.sub','c6111111-1111-4111-8111-111111111111',true);
do $$ declare amount numeric; first uuid; replay uuid; begin
 for amount in select * from (values (0::numeric),(100),(120),('NaN'::numeric),(null::numeric)) a(value) loop
  begin
   perform public.resolve_dispute(current_setting('test.dispute')::uuid,'partially_accepted','Correct the amount',amount,gen_random_uuid());
   raise exception 'Invalid corrected amount accepted';
  exception when sqlstate '22023' then null; end;
 end loop;
 begin
  perform public.resolve_dispute(current_setting('test.cancel')::uuid,'accepted','Cancel this operation',10,gen_random_uuid());
  raise exception 'Cancellation accepted a replacement amount';
 exception when sqlstate '22023' then null; end;
 begin
  perform public.resolve_dispute(current_setting('test.cancel')::uuid,'accepted',' ',null,gen_random_uuid());
  raise exception 'Missing decision reason accepted';
 exception when sqlstate '22023' then null; end;
 begin
  perform public.resolve_dispute(current_setting('test.cancel')::uuid,null,'Decision is missing',null,gen_random_uuid());
  raise exception 'Missing decision accepted';
 exception when sqlstate '22023' then null; end;
 if (select count(*) from public.ledger_entries where business_customer_id=current_setting('test.bc')::uuid)<>5 then
  raise exception 'Invalid decision changed financial entries'; end if;
 first:=public.resolve_dispute(current_setting('test.dispute')::uuid,'partially_accepted','Correct the amount',80,'d7555555-5555-4555-8555-555555555555');
 replay:=public.resolve_dispute(current_setting('test.dispute')::uuid,'partially_accepted','Correct the amount',80,'d7555555-5555-4555-8555-555555555555');
 if first is null or first is distinct from replay then raise exception 'Correction replay failed'; end if;
 begin
  perform public.resolve_dispute(current_setting('test.dispute')::uuid,'partially_accepted','Correct the amount',70,'d7555555-5555-4555-8555-555555555555');
  raise exception 'Same request accepted a different amount';
 exception when sqlstate '22023' then null; end;
 begin
  perform public.resolve_dispute(current_setting('test.dispute')::uuid,'partially_accepted','Changed decision reason',80,'d7555555-5555-4555-8555-555555555555');
  raise exception 'Same request accepted a different reason';
 exception when sqlstate '22023' then null; end;
 begin
  perform public.resolve_dispute(current_setting('test.cancel')::uuid,'accepted','Cancel this operation',null,'d7555555-5555-4555-8555-555555555555');
  raise exception 'Same request accepted another dispute';
 exception when sqlstate '22023' then null; end;
 first:=public.resolve_dispute(current_setting('test.cancel')::uuid,'accepted','Cancel this operation',null,'d7666666-6666-4666-8666-666666666666');
 replay:=public.resolve_dispute(current_setting('test.cancel')::uuid,'accepted','Cancel this operation',null,'d7666666-6666-4666-8666-666666666666');
 if first is null or first is distinct from replay then raise exception 'Cancellation replay failed'; end if;
 first:=public.resolve_dispute(current_setting('test.reject')::uuid,'rejected','Original amount is valid',null,'d7777777-7777-4777-8777-777777777777');
 replay:=public.resolve_dispute(current_setting('test.reject')::uuid,'rejected','Original amount is valid',null,'d7777777-7777-4777-8777-777777777777');
 if first is not null or replay is not null then raise exception 'Rejection changed financial entries'; end if;
 first:=public.resolve_dispute(current_setting('test.sar')::uuid,'partially_accepted','Correct the payment amount',25,'d7888888-8888-4888-8888-888888888888');
 if not exists(select 1 from public.ledger_entries e where e.id=first and e.entry_type='payment' and e.amount=25 and e.currency_code='SAR' and e.direction='credit') then
  raise exception 'Payment correction changed currency or direction'; end if;
end $$;
select set_config('request.jwt.claim.sub','c6222222-2222-4222-8222-222222222222',true);
do $$ declare item jsonb; begin
 if (select current_balance from public.customer_business_summary where business_customer_id=current_setting('test.bc')::uuid and currency_code='YER')<>110 then
  raise exception 'Debt correction, cancellation or rejection has wrong balance'; end if;
 if (select current_balance from public.customer_business_summary where business_customer_id=current_setting('test.bc')::uuid and currency_code='SAR')<>-25 then
  raise exception 'Payment correction has wrong balance'; end if;
 select document into item from public.customer_disputes_page() where id=current_setting('test.dispute')::uuid;
 if (item->>'corrected_amount')::numeric<>80 or item->>'status'<>'partially_accepted' then
  raise exception 'Customer cannot see corrected outcome'; end if;
 begin
  perform public.resolve_dispute(current_setting('test.reject')::uuid,'rejected','Original amount is valid',null,'d7777777-7777-4777-8777-777777777777');
  raise exception 'Customer replayed merchant decision';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
-- A request saved by a prior release has no explicit amount/reason in result.
update public.command_receipts set result=result-'resolution_note'-'corrected_amount'
where idempotency_key='d7555555-5555-4555-8555-555555555555';
set local role authenticated;
select set_config('request.jwt.claim.sub','c6111111-1111-4111-8111-111111111111',true);
select public.resolve_dispute(current_setting('test.dispute')::uuid,'partially_accepted','Correct the amount',80,'d7555555-5555-4555-8555-555555555555');
reset role;
do $$ begin
 if (select count(*) from public.ledger_entries where business_customer_id=current_setting('test.bc')::uuid)<>10 then
  raise exception 'Replay duplicated or removed a financial entry'; end if;
 if (select count(*) from public.dispute_events where dispute_id in
  (current_setting('test.dispute')::uuid,current_setting('test.cancel')::uuid,current_setting('test.reject')::uuid,current_setting('test.sar')::uuid)
  and event_type in ('accepted','partially_accepted','rejected'))<>4 then
  raise exception 'Decision audit events duplicated'; end if;
 if has_function_privilege('anon','public.resolve_dispute(uuid,public.dispute_current_status,text,numeric,uuid)','execute') then
  raise exception 'Anonymous decision endpoint exposed'; end if;
end $$;
rollback;

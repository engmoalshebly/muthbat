-- Synthetic fixtures roll back. Exercises real grants/RLS and both RPC signatures.
begin;
select plan(1);

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
select set_config('test.dispute',public.open_dispute(current_setting('test.debt')::uuid,'wrong_amount','contract test')::text,true);
select set_config('request.jwt.claim.sub','c6111111-1111-4111-8111-111111111111',true);
do $$ declare affected integer; first_id uuid; replay uuid; begin
 update public.businesses set name='Verified profile', country_code='SA', city='Aden'
 where owner_user_id=auth.uid();
 get diagnostics affected=row_count;
 if affected<>1 then raise exception 'Owner profile update not confirmed'; end if;
 begin
  update public.businesses set updated_at=now() where owner_user_id=auth.uid();
  raise exception 'Server timestamp must not be client editable';
 exception when insufficient_privilege then null; end;
 begin
  update public.businesses set owner_user_id='c6333333-3333-4333-8333-333333333333' where owner_user_id=auth.uid();
  raise exception 'Ownership column must remain protected';
 exception when insufficient_privilege then null; end;
 first_id:=public.add_dispute_message(current_setting('test.dispute')::uuid,'merchant reply','c6777777-7777-4777-8777-777777777777','merchant');
 replay:=public.add_dispute_message(current_setting('test.dispute')::uuid,'merchant reply','c6777777-7777-4777-8777-777777777777','merchant');
 if first_id is distinct from replay then raise exception 'Message replay duplicated'; end if;
 if (select sender_workspace from public.dispute_messages where id=first_id)<>'merchant' then raise exception 'Wrong merchant workspace'; end if;
 begin
  perform public.add_dispute_message(current_setting('test.dispute')::uuid,'changed reply','c6777777-7777-4777-8777-777777777777','merchant');
  raise exception 'Changed replay accepted';
 exception when sqlstate '22023' then null; end;
 begin
  perform public.add_dispute_message(current_setting('test.dispute')::uuid,' ','c6888888-8888-4888-8888-888888888888','merchant');
  raise exception 'Blank message accepted';
 exception when sqlstate '22023' then null; end;
 begin
  perform public.add_dispute_message(current_setting('test.dispute')::uuid,'x',gen_random_uuid(),null);
  raise exception 'Null workspace accepted';
 exception when sqlstate '22023' then null; end;
end $$;
select set_config('request.jwt.claim.sub','c6222222-2222-4222-8222-222222222222',true);
select public.submit_customer_action('c6999999-9999-4999-8999-999999999999',jsonb_build_object('kind','dispute_reply','target_id',current_setting('test.dispute'),'message','customer reply'));
select public.submit_customer_action('c6999999-9999-4999-8999-999999999999',jsonb_build_object('kind','dispute_reply','target_id',current_setting('test.dispute'),'message','customer reply'));
do $$ declare item jsonb; affected integer; begin
 select document into item from public.customer_disputes_page() where id=current_setting('test.dispute')::uuid;
 if jsonb_array_length(item->'messages')<>2 or item->>'status'<>'awaiting_merchant' then raise exception 'Customer conversation or state missing'; end if;
 update public.businesses set city='Intruder' where id=(select business_id from public.disputes where id=current_setting('test.dispute')::uuid);
 get diagnostics affected=row_count;
 if affected<>0 then raise exception 'Customer changed merchant profile'; end if;
 begin
  perform public.add_dispute_message(current_setting('test.dispute')::uuid,'spoof',gen_random_uuid(),'merchant');
  raise exception 'Customer spoofed merchant';
 exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','c6333333-3333-4333-8333-333333333333',true);
do $$ begin
 begin
  perform public.add_dispute_message(current_setting('test.dispute')::uuid,'intruder',gen_random_uuid(),'merchant');
  raise exception 'Outsider reply accepted';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
 if (select count(*) from public.notifications where entity_id=current_setting('test.dispute')::uuid
     and type='dispute_reply')<>2 then raise exception 'Reply notification duplication or missing'; end if;
 if exists(select 1 from public.notifications where entity_id=current_setting('test.dispute')::uuid
     and type='dispute_reply' and data->>'workspace' is distinct from
       case when user_id='c6111111-1111-4111-8111-111111111111'::uuid then 'merchant' else 'customer' end) then
   raise exception 'Reply notification targets wrong workspace'; end if;
 if has_function_privilege('anon','public.add_dispute_message(uuid,text,uuid,text)','execute') then raise exception 'Anonymous execute granted'; end if;
 if has_table_privilege('authenticated','public.businesses','UPDATE') then raise exception 'Broad table UPDATE granted'; end if;
end $$;
select pass('Profile sync and dispute RPC contracts enforce grants and RLS as expected');
select * from finish();
rollback;

-- Transactional event generation, token lifecycle, RLS, retries and automation.
begin;
do $$
declare
 u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); b uuid;
 c uuid; bc uuid; e uuid; d uuid := gen_random_uuid(); n uuid; o bigint;
 r uuid; a uuid; t uuid; v_count bigint;
begin
 insert into auth.users(id) values(u1),(u2);
 perform set_config('request.jwt.claim.sub',u1::text,true);
 insert into public.businesses(owner_user_id,name,business_type,currency_code)
 values(u1,'Notification test','grocery','YER') returning id into b;
 insert into public.business_members(business_id,user_id,role) values(b,u1,'owner');
 if (select count(*) from public.automation_rules where business_id=b and rule_key like 'default_%')<>3 then raise exception 'Default rules missing'; end if;
 select id into c from public.customers where user_id=u2;
 insert into public.business_customers(business_id,customer_id,local_display_name,link_status,created_by_user_id)
 values(b,c,'Test customer','linked',u1) returning id into bc;
 insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,client_request_id,created_by_user_id)
 values(b,bc,c,'debt','debit',100,'YER','Notification debt',gen_random_uuid(),u1) returning id into e;
 select id into n from public.notifications where entity_id=e and user_id=u2;
 if n is null or not exists(select 1 from public.notifications where id=n and title like 'دين جديد%' and data->>'currency'='YER') then raise exception 'Debt notification missing'; end if;
 select id into o from private.notification_outbox where notification_id=n;
 if o is null then raise exception 'Transactional outbox missing'; end if;
 insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,client_request_id,created_by_user_id)
 values(b,bc,c,'payment','credit',20,'YER','Notification payment',gen_random_uuid(),u1) returning id into e;
 if not exists(select 1 from public.notifications where entity_id=e and user_id=u2 and title like 'سداد جديد%') then raise exception 'Payment notification missing'; end if;
 update public.business_customers set link_status='unlinked' where id=bc;
 insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,client_request_id,created_by_user_id)
 values(b,bc,c,'debt','debit',5,'YER','Unlinked customer',gen_random_uuid(),u1) returning id into e;
 if exists(select 1 from public.notifications where entity_id=e) then raise exception 'Unlinked customer received financial notification'; end if;

 perform public.register_android_push_token(d,repeat('a',40));
 perform public.register_android_push_token(d,repeat('b',40));
 select count(*) into v_count from public.device_push_tokens where user_id=u1 and device_id=d;
 if v_count<>1 or not exists(select 1 from public.device_push_tokens where user_id=u1 and push_token=repeat('b',40)) then raise exception 'Token rotation failed'; end if;
 perform set_config('request.jwt.claim.sub',u2::text,true);
 perform public.register_android_push_token(d,repeat('b',40));
 if exists(select 1 from public.device_push_tokens where user_id=u1 and push_token=repeat('b',40)) then raise exception 'Account switch leaked token'; end if;
 select id into t from public.device_push_tokens where user_id=u2 and push_token=repeat('b',40);
 if t is null then raise exception 'New account token missing'; end if;

 perform public.service_finish_notification(o,false);
 if exists(select 1 from public.notifications where id=n and delivery_status='sent') then raise exception 'In-app only incorrectly marked sent'; end if;
 perform public.service_record_notification_delivery_attempt(o,'fcm',t,'sent','{}',null);
 if not public.service_notification_device_sent(o,t) then raise exception 'Per-device retry dedup missing'; end if;
 perform public.service_finish_notification(o,true);
 if not exists(select 1 from public.notifications where id=n and delivery_status='sent') then raise exception 'Push acceptance not recorded'; end if;

 insert into public.automation_rules(business_id,rule_key,trigger_type,message_template,created_by_user_id)
 values(b,'test-notification','on_due','Test reminder',u1) returning id into a;
 insert into public.automation_runs(rule_id,business_customer_id,run_key) values(a,bc,gen_random_uuid()::text) returning id into r;
 perform public.service_dispatch_automation(r,u2,'payment_due','Test reminder','Test body','ledger_entry',e,'{}',true);
 perform public.service_dispatch_automation(r,u2,'payment_due','Test reminder','Test body','ledger_entry',e,'{}',true);
 select count(*) into v_count from public.notifications where data->>'automation_run_id'=r::text;
 if v_count<>1 then raise exception 'Automation duplicated notification'; end if;
 select count(*) into v_count from public.reminders where business_id=b;
 if v_count<>1 then raise exception 'Automation duplicated reminder'; end if;
 if exists(select 1 from public.reminders where business_id=b and status='sent') then raise exception 'Reminder falsely marked sent'; end if;

 if has_function_privilege('anon','public.register_android_push_token(uuid,text)','execute') then raise exception 'Anonymous token registration allowed'; end if;
 if has_function_privilege('authenticated','public.service_dispatch_automation(uuid,uuid,public.notification_type,text,text,text,uuid,jsonb,boolean)','execute') then raise exception 'Client can dispatch automation'; end if;
 insert into public.notification_preferences(user_id,push_enabled) values(u1,false),(u2,true);
end $$;

set local role authenticated;
-- The current JWT is user 2; neither preferences nor notifications of user 1 may leak.
do $$ begin
 if (select count(*) from public.notification_preferences)<>1 then raise exception 'Preferences RLS leaked another account'; end if;
 if exists(select 1 from public.notification_preferences where user_id<>auth.uid()) then raise exception 'Preferences ownership broken'; end if;
 if exists(select 1 from public.notifications where user_id<>auth.uid()) then raise exception 'Notification ownership broken'; end if;
end $$;
reset role;
rollback;

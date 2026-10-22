begin;

create table public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  push_enabled boolean not null default true,
  financial_enabled boolean not null default true,
  disputes_enabled boolean not null default true,
  reminders_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.notification_preferences enable row level security;
grant select,insert,update on public.notification_preferences to authenticated;
grant all on public.notification_preferences to service_role;
create policy notification_preferences_own on public.notification_preferences
for all to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));

-- A device installation belongs to only one currently signed-in account.
-- The caller proves possession of the FCM token received on this installation.
create function public.register_android_push_token(p_device_id uuid,p_token text)
returns void language plpgsql security definer set search_path='' as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'unauthorized'; end if;
  if length(p_token)<20 or length(p_token)>4096 or p_device_id is null then raise exception 'invalid_token'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_token,0));
  delete from public.device_push_tokens where push_token=p_token and (user_id<>v_user or device_id<>p_device_id);
  insert into public.device_push_tokens(user_id,device_id,platform,push_token,is_active)
  values(v_user,p_device_id,'android',p_token,true)
  on conflict(user_id,device_id) do update set push_token=excluded.push_token,platform='android',is_active=true,last_seen_at=now(),updated_at=now();
end $$;
revoke all on function public.register_android_push_token(uuid,text) from public,anon;
grant execute on function public.register_android_push_token(uuid,text) to authenticated;

create function public.service_enqueue_notification(
 p_user_id uuid,p_type public.notification_type,p_title text,p_body text,
 p_entity_type text default null,p_entity_id uuid default null,p_data jsonb default '{}'
) returns uuid language sql security definer set search_path='' as $$
 select private.enqueue_notification(p_user_id,p_type,p_title,p_body,p_entity_type,p_entity_id,p_data)
$$;
revoke all on function public.service_enqueue_notification(uuid,public.notification_type,text,text,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.service_enqueue_notification(uuid,public.notification_type,text,text,text,uuid,jsonb) to service_role;

-- Include trusted routing metadata, never a client-supplied route.
create or replace function private.service_claim_notification_batch(p_limit integer default 100)
returns table(outbox_id bigint,notification_id uuid,user_id uuid,notification_type public.notification_type,title text,body text,data jsonb)
language sql volatile security definer set search_path='' as $$
 with candidates as (
  select o.id from private.notification_outbox o where o.processed_at is null
  and o.available_at<=now() and (o.locked_at is null or o.locked_at<now()-interval '5 minutes')
  order by o.id for update skip locked limit greatest(1,least(p_limit,100))
 ), claimed as (
  update private.notification_outbox o set locked_at=now(),attempt_count=o.attempt_count+1
  from candidates c where o.id=c.id returning o.id,o.notification_id
 ) select c.id,n.id,n.user_id,n.type,n.title,n.body,n.data || jsonb_build_object(
 'notification_id',n.id,'user_id',n.user_id,'type',n.type,'entity_type',n.entity_type,'entity_id',n.entity_id)
 from claimed c join public.notifications n on n.id=c.notification_id order by c.id
$$;

-- Completing in-app-only jobs must not pretend that a push was sent.
create function public.service_finish_notification(p_outbox_id bigint,p_sent boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 update private.notification_outbox set processed_at=now(),locked_at=null,last_error=null where id=p_outbox_id;
 if p_sent then
 update public.notifications n set delivery_status=case when n.read_at is null then 'sent'::public.notification_delivery_status else 'read'::public.notification_delivery_status end
 from private.notification_outbox o where o.id=p_outbox_id and o.notification_id=n.id;
 end if;
end $$;
revoke all on function public.service_finish_notification(bigint,boolean) from public,anon,authenticated;
grant execute on function public.service_finish_notification(bigint,boolean) to service_role;

-- Enrich the existing transactional event without generating a second notice.
create function private.enrich_financial_notification() returns trigger
language plpgsql security definer set search_path='' as $$
declare e public.ledger_entries; v_business text; v_label text;
begin
 if new.type='ledger_created' and new.entity_type='ledger_entry' then
  select * into e from public.ledger_entries where id=new.entity_id;
  select name into v_business from public.businesses where id=e.business_id;
  v_label:=case e.entry_type::text when 'debt' then 'دين جديد' when 'payment' then 'سداد جديد' when 'discount' then 'خصم جديد' when 'reversal' then 'تصحيح عملية' when 'opening_balance' then 'رصيد افتتاحي' else 'عملية جديدة' end;
  new.title:=v_label || ' من ' || coalesce(v_business,'المحل');
  new.body:='تم تسجيل ' || v_label || ' بمبلغ ' || e.amount::text || ' ' || e.currency_code || '. راجع التفاصيل في حسابك.';
  new.data:=new.data || jsonb_build_object('business_id',e.business_id,'business_customer_id',e.business_customer_id,'entry_type',e.entry_type,'currency',e.currency_code);
 end if;
 return new;
end $$;
create trigger enrich_financial_notification before insert on public.notifications
for each row execute function private.enrich_financial_notification();
revoke all on function private.enrich_financial_notification() from public,anon,authenticated;
create function public.service_notification_device_sent(p_outbox_id bigint,p_device_token_id uuid)
returns boolean language sql security definer set search_path='' as $$
 select exists(select 1 from private.notification_delivery_attempts where outbox_id=p_outbox_id and device_token_id=p_device_token_id and status='sent')
$$;
revoke all on function public.service_notification_device_sent(bigint,uuid) from public,anon,authenticated;
grant execute on function public.service_notification_device_sent(bigint,uuid) to service_role;
create index idx_notification_device_sent on private.notification_delivery_attempts(outbox_id,device_token_id) where status='sent';
-- A run's reminder, notification and completion are committed atomically.
create function public.service_dispatch_automation(
 p_run_id uuid,p_user_id uuid,p_type public.notification_type,p_title text,p_body text,
 p_entity_type text,p_entity_id uuid,p_data jsonb,p_push boolean
) returns void language plpgsql security definer set search_path='' as $$
declare r public.automation_runs; a public.automation_rules; v_owner uuid;
begin
 select * into r from public.automation_runs where id=p_run_id for update;
 if not found then raise exception 'run_not_found'; end if;
 if coalesce((r.result->>'dispatched')::boolean,false) then
  update public.automation_runs set status='succeeded' where id=r.id;
  return;
 end if;
 select * into a from public.automation_rules where id=r.rule_id;
 select owner_user_id into v_owner from public.businesses where id=a.business_id;
 if r.business_customer_id is not null then
  insert into public.reminders(business_id,business_customer_id,sent_by_user_id,channel,message_snapshot,status)
  values(a.business_id,r.business_customer_id,v_owner,a.channel,left(p_body,1000),'queued');
 end if;
 if p_user_id is not null then
  perform private.enqueue_notification(p_user_id,p_type,p_title,p_body,p_entity_type,p_entity_id,
   p_data || jsonb_build_object('push',p_push,'automation_run_id',p_run_id));
 end if;
 update public.automation_runs set status='succeeded',completed_at=now(),result=jsonb_build_object('dispatched',true,'enqueued',p_user_id is not null) where id=r.id;
end $$;
revoke all on function public.service_dispatch_automation(uuid,uuid,public.notification_type,text,text,text,uuid,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.service_dispatch_automation(uuid,uuid,public.notification_type,text,text,text,uuid,jsonb,boolean) to service_role;
commit;

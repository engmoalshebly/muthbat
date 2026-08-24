-- Debt Ledger MVP - Operational helpers, outbox worker RPCs, audit and scheduled maintenance
begin;

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function private.try_uuid(p_value text)
returns uuid
language plpgsql immutable
set search_path=''
as $$
begin
  return p_value::uuid;
exception when others then
  return null;
end;
$$;

-- Generic audit for mutable business state. Financial facts remain in append-only tables.
create or replace function private.audit_row_change()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_old jsonb; v_new jsonb; v_row jsonb; v_entity_id text; v_business uuid;
begin
  v_old := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end;
  v_new := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end;
  v_row := coalesce(v_new,v_old);
  v_entity_id := coalesce(v_row->>'id',v_row->>'entry_id',v_row->>'dispute_id');
  begin v_business := nullif(v_row->>'business_id','')::uuid; exception when others then v_business := null; end;
  insert into private.audit_logs(actor_user_id,action,entity_schema,entity_table,entity_id,business_id,old_data,new_data,request_id)
  values((select auth.uid()),tg_op,tg_table_schema,tg_table_name,v_entity_id,v_business,v_old,v_new,coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-request-id');
  return coalesce(new,old);
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['businesses','business_members','business_customers','customer_link_requests','ledger_entry_state','dispute_state','reminders'] loop
    execute format('create trigger trg_%I_audit after insert or update or delete on public.%I for each row execute function private.audit_row_change()',t,t);
  end loop;
end $$;

-- Claim a push-notification batch atomically (SKIP LOCKED permits multiple workers).
create or replace function private.service_claim_notification_batch(p_limit integer default 100)
returns table(
  outbox_id bigint,
  notification_id uuid,
  user_id uuid,
  notification_type public.notification_type,
  title text,
  body text,
  data jsonb
)
language sql volatile security definer set search_path=''
as $$
  with candidates as (
    select o.id
    from private.notification_outbox o
    where o.processed_at is null
      and o.available_at <= now()
      and (o.locked_at is null or o.locked_at < now()-interval '5 minutes')
    order by o.id
    for update skip locked
    limit greatest(1,least(p_limit,500))
  ), claimed as (
    update private.notification_outbox o
    set locked_at=now(),attempt_count=o.attempt_count+1
    from candidates c
    where o.id=c.id
    returning o.id,o.notification_id
  )
  select c.id,n.id,n.user_id,n.type,n.title,n.body,n.data
  from claimed c join public.notifications n on n.id=c.notification_id
  order by c.id
$$;

create or replace function public.service_claim_notification_batch(p_limit integer default 100)
returns table(outbox_id bigint,notification_id uuid,user_id uuid,notification_type public.notification_type,title text,body text,data jsonb)
language sql set search_path=''
as $$ select * from private.service_claim_notification_batch(p_limit) $$;

create or replace function private.service_complete_notification(p_outbox_id bigint)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  update private.notification_outbox set processed_at=now(),locked_at=null,last_error=null where id=p_outbox_id;
  update public.notifications n set delivery_status='sent'
  from private.notification_outbox o where o.id=p_outbox_id and n.id=o.notification_id;
end;
$$;

create or replace function public.service_complete_notification(p_outbox_id bigint)
returns void language sql set search_path=''
as $$ select private.service_complete_notification(p_outbox_id) $$;

create or replace function private.service_fail_notification(p_outbox_id bigint,p_error text)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_attempt smallint;
begin
  select attempt_count into v_attempt from private.notification_outbox where id=p_outbox_id;
  update private.notification_outbox
  set locked_at=null,last_error=left(p_error,2000),
      available_at=now()+make_interval(secs => least(21600,(power(2,least(coalesce(v_attempt,1),8))::integer*60)))
  where id=p_outbox_id;
  update public.notifications n set delivery_status='failed'
  from private.notification_outbox o where o.id=p_outbox_id and n.id=o.notification_id;
end;
$$;

create or replace function public.service_fail_notification(p_outbox_id bigint,p_error text)
returns void language sql set search_path=''
as $$ select private.service_fail_notification(p_outbox_id,p_error) $$;

-- Expire stale link requests and restore the business-customer link state.
create or replace function private.expire_link_requests()
returns integer
language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
  with expired as (
    update public.customer_link_requests
      set status='expired',updated_at=now()
    where status='pending' and expires_at<now()
    returning business_customer_id
  )
  update public.business_customers bc set link_status='unlinked'
  where bc.id in (select business_customer_id from expired) and bc.link_status='pending';
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;

-- Idempotent schedule creation.
do $$
begin
  if not exists(select 1 from cron.job where jobname='expire-customer-link-requests') then
    perform cron.schedule('expire-customer-link-requests','*/15 * * * *','select private.expire_link_requests();');
  end if;
end $$;

-- Lock down service worker RPCs.
revoke all on function private.service_claim_notification_batch(integer) from public,anon,authenticated;
revoke all on function private.service_complete_notification(bigint) from public,anon,authenticated;
revoke all on function private.service_fail_notification(bigint,text) from public,anon,authenticated;
revoke all on function public.service_claim_notification_batch(integer) from public,anon,authenticated;
revoke all on function public.service_complete_notification(bigint) from public,anon,authenticated;
revoke all on function public.service_fail_notification(bigint,text) from public,anon,authenticated;
grant execute on function public.service_claim_notification_batch(integer) to service_role;
grant execute on function public.service_complete_notification(bigint) to service_role;
grant execute on function public.service_fail_notification(bigint,text) to service_role;
grant execute on function private.service_claim_notification_batch(integer) to service_role;
grant execute on function private.service_complete_notification(bigint) to service_role;
grant execute on function private.service_fail_notification(bigint,text) to service_role;

commit;

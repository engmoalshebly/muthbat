begin;

alter table public.dispute_messages
  add column if not exists sender_workspace text;

alter table public.dispute_messages
  drop constraint if exists dispute_messages_sender_workspace_check;
alter table public.dispute_messages
  add constraint dispute_messages_sender_workspace_check
  check (sender_workspace is null or sender_workspace in ('customer', 'merchant'));

-- Customer replies go through submit_customer_action and the legacy 3-argument
-- entry point. Their source is unambiguous because that RPC is customer-only.
create or replace function public.add_dispute_message(
  p_dispute_id uuid,
  p_message text,
  p_client_request_id uuid default null
)
returns uuid
language sql
set search_path=''
as $$
  with saved as materialized (
    select private.command_add_dispute_message(
      p_dispute_id, p_message, p_client_request_id
    ) as id
  ), marked as (
    update public.dispute_messages m
       set sender_workspace='customer'
      from saved
     where m.id=saved.id
    returning m.id
  )
  select id from marked
$$;

create or replace function private.command_add_dispute_message(
  p_dispute_id uuid,
  p_message text,
  p_client_request_id uuid,
  p_sender_workspace text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_d public.disputes%rowtype;
  v_status public.dispute_current_status;
  v_id uuid;
  v_is_customer boolean;
  v_target uuid;
  v_event public.dispute_event_type;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  if p_sender_workspace not in ('customer','merchant') then
    raise exception 'Invalid sender workspace' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  select * into v_d from public.disputes where id=p_dispute_id;
  if not found then raise exception 'Dispute not found'; end if;
  select status into v_status from public.dispute_state where dispute_id=p_dispute_id for update;
  if not found then raise exception 'Dispute state not found'; end if;

  v_is_customer := p_sender_workspace='customer';
  if v_is_customer then
    if not (private.is_customer_owner(v_d.customer_id)
      and private.can_customer_access_business_customer(
        (select business_customer_id from public.ledger_entries where id=v_d.entry_id)
      )) then
      raise exception 'Not authorized as customer' using errcode='42501';
    end if;
  elsif not private.is_business_member(
    v_d.business_id,
    array['owner','admin','accountant','collector']::public.business_role[]
  ) then
    raise exception 'Not authorized as merchant' using errcode='42501';
  end if;

  select result_entity_id into v_id from public.command_receipts
   where idempotency_key=v_request_id and command_type='add_dispute_message';
  if found then return v_id; end if;
  if v_status not in ('awaiting_merchant','awaiting_customer','open','escalated') then
    raise exception 'Dispute is already resolved' using errcode='55000';
  end if;
  insert into public.dispute_messages(
    dispute_id,sender_user_id,sender_workspace,message
  ) values (
    p_dispute_id,(select auth.uid()),p_sender_workspace,trim(p_message)
  ) returning id into v_id;

  if v_is_customer then
    update public.dispute_state set status='awaiting_merchant' where dispute_id=p_dispute_id;
    v_event:='customer_replied';
    select owner_user_id into v_target from public.businesses where id=v_d.business_id;
  else
    update public.dispute_state set status='awaiting_customer' where dispute_id=p_dispute_id;
    v_event:='merchant_requested_information';
    select user_id into v_target from public.customers where id=v_d.customer_id;
  end if;
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note)
    values(p_dispute_id,v_event,(select auth.uid()),trim(p_message));
  if v_target is not null and v_target<>(select auth.uid()) then
    perform private.enqueue_notification(
      v_target,'dispute_reply','رد جديد على الاعتراض',
      'يوجد رد جديد في الاعتراض.','dispute',p_dispute_id,'{}'::jsonb
    );
  end if;
  insert into public.command_receipts(
    idempotency_key,user_id,command_type,status,result_entity_id,result
  ) values (
    v_request_id,(select auth.uid()),'add_dispute_message','accepted',v_id,
    jsonb_build_object('message_id',v_id,'dispute_id',p_dispute_id)
  ) on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function public.add_dispute_message(
  p_dispute_id uuid,
  p_message text,
  p_client_request_id uuid,
  p_sender_workspace text
)
returns uuid
language sql
set search_path=''
as $$
  select private.command_add_dispute_message(
    p_dispute_id,p_message,p_client_request_id,p_sender_workspace
  )
$$;

revoke all on function public.add_dispute_message(uuid,text,uuid) from public,anon,authenticated;
revoke all on function private.command_add_dispute_message(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.add_dispute_message(uuid,text,uuid,text) from public,anon;
grant execute on function public.add_dispute_message(uuid,text,uuid,text) to authenticated;
revoke all on function private.command_add_dispute_message(uuid,text,uuid,text) from public,anon;
grant execute on function private.command_add_dispute_message(uuid,text,uuid,text) to authenticated;

commit;

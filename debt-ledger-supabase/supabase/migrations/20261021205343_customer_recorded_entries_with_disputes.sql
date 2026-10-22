begin;
-- Amounts are already accounted for at insertion. Keep historical customer
-- acknowledgments intact; never fabricate a confirmation on the customer's behalf.
create or replace function private.command_open_dispute(
  p_entry_id uuid,
  p_reason public.dispute_reason,
  p_description text,
  p_client_request_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_entry public.ledger_entries%rowtype;
  v_dispute uuid;
  v_owner uuid;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  if p_description is null or length(trim(p_description)) not between 1 and 4000 then
    raise exception 'Invalid dispute description' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  select * into v_entry from public.ledger_entries where id=p_entry_id;
  if not found or not private.is_customer_owner(v_entry.customer_id)
     or not private.can_customer_access_business_customer(v_entry.business_customer_id) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_entry_id::text,0));
  select result_entity_id into v_dispute from public.command_receipts
   where idempotency_key=v_request_id and command_type='open_dispute';
  if found then return v_dispute; end if;
  if exists(select 1 from public.disputes d join public.dispute_state ds on ds.dispute_id=d.id
            where d.entry_id=p_entry_id and ds.status in ('open','awaiting_merchant','awaiting_customer','escalated')) then
    raise exception 'An active dispute already exists';
  end if;
  -- Registration and previous acknowledgment never waive the right to dispute.
  if exists(select 1 from public.ledger_entry_state where entry_id=p_entry_id and is_reversed) then
    raise exception 'Cannot dispute a reversed entry';
  end if;
  insert into public.disputes(entry_id,business_id,customer_id,opened_by_user_id,reason,description)
    values(p_entry_id,v_entry.business_id,v_entry.customer_id,(select auth.uid()),p_reason,trim(p_description)) returning id into v_dispute;
  insert into public.dispute_state(dispute_id,status) values(v_dispute,'awaiting_merchant');
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note) values(v_dispute,'opened',(select auth.uid()),trim(p_description));
  update public.ledger_entry_state set dispute_status='open',last_event_at=now() where entry_id=p_entry_id;
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id,metadata)
    values(p_entry_id,v_entry.business_id,v_entry.customer_id,'disputed',(select auth.uid()),jsonb_build_object('dispute_id',v_dispute));
  select owner_user_id into v_owner from public.businesses where id=v_entry.business_id;
  perform private.enqueue_notification(v_owner,'ledger_disputed','اعتراض جديد','اعترض العميل على عملية مسجلة.','dispute',v_dispute,jsonb_build_object('entry_id',p_entry_id));
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'open_dispute','accepted',v_dispute,jsonb_build_object('dispute_id',v_dispute))
  on conflict(idempotency_key) do nothing;
  return v_dispute;
end;
$$;

create or replace function private.after_ledger_entry_insert()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_customer_user uuid; v_link public.customer_link_status; v_confirmation public.entry_confirmation_status; v_owner uuid;
begin
  select c.user_id, bc.link_status into v_customer_user, v_link
  from public.customers c join public.business_customers bc on bc.customer_id=c.id
  where c.id=new.customer_id and bc.id=new.business_customer_id;

  v_confirmation := case when v_customer_user is not null and v_link='linked' then 'pending' else 'not_available' end;
  insert into public.ledger_entry_state(entry_id,confirmation_status) values(new.id,v_confirmation);
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id)
  values(new.id,new.business_id,new.customer_id,'created',new.created_by_user_id);

  if new.entry_type='reversal' then
    update public.ledger_entry_state set is_reversed=true,reversal_entry_id=new.id,last_event_at=now()
      where entry_id=new.reversal_of_entry_id;
    insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id,metadata)
      values(new.reversal_of_entry_id,new.business_id,new.customer_id,'reversed',new.created_by_user_id,jsonb_build_object('reversal_entry_id',new.id));
  end if;

  if v_customer_user is not null and v_link='linked' then
    perform private.enqueue_notification(v_customer_user,'ledger_created',
      case when new.entry_type='payment' then 'تم تسجيل دفعة' else 'تم تسجيل عملية جديدة' end,
      'أُضيفت العملية إلى حسابك مباشرة. يمكنك مراجعة التفاصيل وتقديم اعتراض عند الحاجة.',
      'ledger_entry',new.id,jsonb_build_object('business_id',new.business_id,'entry_type',new.entry_type,'amount',new.amount));
    insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id)
      values(new.id,new.business_id,new.customer_id,'notification_queued',new.created_by_user_id);
  end if;
  return new;
end;
$$;

revoke all on function private.command_open_dispute(uuid,public.dispute_reason,text,uuid) from public,anon;
grant execute on function private.command_open_dispute(uuid,public.dispute_reason,text,uuid) to authenticated;
revoke all on function private.after_ledger_entry_insert() from public,anon,authenticated;
commit;

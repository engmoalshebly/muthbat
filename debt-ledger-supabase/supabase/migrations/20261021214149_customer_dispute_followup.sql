begin;
create or replace function private.command_resolve_dispute(
  p_dispute_id uuid,
  p_resolution public.dispute_current_status,
  p_resolution_note text,
  p_corrected_amount numeric default null,
  p_client_request_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_d public.disputes%rowtype;
  v_current public.dispute_current_status;
  v_entry public.ledger_entries%rowtype;
  v_reversal uuid;
  v_corrected uuid;
  v_replay uuid;
  v_customer_user uuid;
  v_event public.dispute_event_type;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  select * into v_d from public.disputes where id=p_dispute_id;
  if not found then raise exception 'Dispute not found'; end if;
  select status into v_current from public.dispute_state where dispute_id=p_dispute_id for update;
  if not found then raise exception 'Dispute state not found'; end if;
  if not private.is_business_member(v_d.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select result_entity_id into v_replay from public.command_receipts
   where idempotency_key=v_request_id and command_type='resolve_dispute';
  if found then return v_replay; end if;
  if v_current not in ('open','awaiting_merchant','awaiting_customer','escalated') then
    raise exception 'Dispute is already resolved' using errcode='55000';
  end if;
  if p_resolution not in ('accepted','partially_accepted','rejected') then raise exception 'Invalid resolution'; end if;
  if p_resolution='rejected' and p_corrected_amount is not null then
    raise exception 'Corrected amount is only allowed for a partially accepted resolution';
  end if;
  select * into v_entry from public.ledger_entries where id=v_d.entry_id;
  if p_resolution in ('accepted','partially_accepted') then
    v_reversal:=private.command_reverse_ledger_entry(v_entry.id,left('تصحيح بسبب اعتراض: '||trim(p_resolution_note),500),gen_random_uuid(),true);
  end if;
  if p_resolution='partially_accepted' then
    if p_corrected_amount is null or p_corrected_amount<=0 or p_corrected_amount>=v_entry.amount then
      raise exception 'Corrected amount must be between zero and original amount';
    end if;
    if v_entry.entry_type='discount' then
      v_corrected:=private.command_apply_customer_discount(
        v_entry.business_customer_id,p_corrected_amount,
        'قيمة مصححة للعملية '||v_entry.id::text,v_entry.occurred_at,gen_random_uuid(),v_entry.currency_code);
    else
      v_corrected:=private.command_create_ledger_entry(
        v_entry.business_customer_id,v_entry.entry_type,p_corrected_amount,
        'قيمة مصححة للعملية '||v_entry.id::text,v_entry.occurred_at,v_entry.due_date,v_entry.external_reference,gen_random_uuid(),null,
        coalesce(v_entry.category::text,'goods'),coalesce(v_entry.payment_method::text,'cash'),v_entry.reference_number,v_entry.bank_or_agent_name,v_entry.attachment_url,v_entry.currency_code);
    end if;
  end if;
  update public.dispute_state set status=p_resolution,resolution_note=trim(p_resolution_note),resolved_by_user_id=(select auth.uid()),resolved_at=now()
   where dispute_id=p_dispute_id;
  update public.ledger_entry_state set dispute_status='resolved',last_event_at=now() where entry_id=v_entry.id;
  v_event:=case p_resolution when 'accepted' then 'accepted'::public.dispute_event_type when 'partially_accepted' then 'partially_accepted'::public.dispute_event_type else 'rejected'::public.dispute_event_type end;
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note,metadata)
    values(p_dispute_id,v_event,(select auth.uid()),trim(p_resolution_note),jsonb_build_object('reversal_entry_id',v_reversal,'corrected_entry_id',v_corrected,'currency_code',v_entry.currency_code));
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id,metadata)
    values(v_entry.id,v_entry.business_id,v_entry.customer_id,'dispute_resolved',(select auth.uid()),jsonb_build_object('resolution',p_resolution,'currency_code',v_entry.currency_code));
  select user_id into v_customer_user from public.customers where id=v_d.customer_id;
  if v_customer_user is not null then
    perform private.enqueue_notification(v_customer_user,'dispute_resolved','تمت معالجة الاعتراض','راجع نتيجة الاعتراض داخل التطبيق.','dispute',p_dispute_id,jsonb_build_object('resolution',p_resolution));
  end if;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
    values(v_request_id,(select auth.uid()),'resolve_dispute','accepted',coalesce(v_corrected,v_reversal),jsonb_build_object('dispute_id',p_dispute_id,'resolution',p_resolution,'reversal_entry_id',v_reversal,'corrected_entry_id',v_corrected,'currency_code',v_entry.currency_code))
    on conflict(idempotency_key) do nothing;
  return coalesce(v_corrected,v_reversal);
end;
$$;
create or replace function public.submit_customer_action(p_request_id uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_existing jsonb; v_target uuid; v_kind text;
begin
  if v_user is null or not exists(select 1 from public.profiles where id=v_user and status='active') then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  if p_request_id is null or p_payload is null then raise exception 'Invalid action'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('customer-action:'||v_user::text||':'||p_request_id::text,0));
  select payload into v_existing from private.customer_action_receipts where user_id=v_user and request_id=p_request_id;
  if found then
    if v_existing<>p_payload then raise exception 'Request payload mismatch' using errcode='22023'; end if;
    return jsonb_build_object('completed',true,'replayed',true);
  end if;
  v_kind:=p_payload->>'kind'; v_target:=(p_payload->>'target_id')::uuid;
  if v_kind in ('confirm','dispute') then
    -- Consent and current ownership are rechecked at execution, not when queued.
    if not exists(select 1 from public.ledger_entries le
      join public.customers c on c.id=le.customer_id
      join public.business_customers bc on bc.id=le.business_customer_id
      join public.businesses b on b.id=bc.business_id
      join public.ledger_entry_state s on s.entry_id=le.id
      where le.id=v_target and c.user_id=v_user and c.status='active'
        and bc.link_status='linked' and not bc.is_archived and b.status='active' and not s.is_reversed) then
      raise exception 'Not authorized or entry unavailable' using errcode='42501';
    end if;
    if v_kind='confirm' then
      perform public.confirm_ledger_entry(v_target);
    else
      if length(trim(coalesce(p_payload->>'description','')))<1 or length(p_payload->>'description')>4000 then raise exception 'Invalid description'; end if;
      perform public.open_dispute(v_target,(p_payload->>'reason')::public.dispute_reason,p_payload->>'description');
    end if;
  elsif v_kind='dispute_reply' then
    if length(trim(coalesce(p_payload->>'message',''))) not between 1 and 4000 then
      raise exception 'Invalid message' using errcode='22023';
    end if;
    if not exists(select 1 from public.disputes d join public.ledger_entries e on e.id=d.entry_id
      where d.id=v_target and private.is_customer_owner(d.customer_id)
      and private.can_customer_access_business_customer(e.business_customer_id)) then
      raise exception 'Not authorized' using errcode='42501';
    end if;
    perform public.add_dispute_message(v_target,p_payload->>'message',p_request_id);
  elsif v_kind='link' then
    if jsonb_typeof(p_payload->'accept')<>'boolean' or not (p_payload ? 'accept') then raise exception 'Invalid consent'; end if;
    perform public.respond_link_request(v_target,(p_payload->>'accept')::boolean);
  else raise exception 'Unknown customer action';
  end if;
  insert into private.customer_action_receipts(user_id,request_id,payload) values(v_user,p_request_id,p_payload);
  return jsonb_build_object('completed',true,'replayed',false);
end;
$$;
revoke all on function public.submit_customer_action(uuid,jsonb) from public,anon;
grant execute on function public.submit_customer_action(uuid,jsonb) to authenticated;

create or replace function public.customer_disputes_page(p_after uuid default null,p_limit integer default 50)
returns table(id uuid, document jsonb)
language plpgsql security invoker set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_limit not between 1 and 50 then raise exception 'Invalid limit' using errcode='22023'; end if;
 return query
 select d.id, to_jsonb(d)||jsonb_build_object(
   'status',s.status,'resolution_note',s.resolution_note,'resolved_at',s.resolved_at,
   'business_name',b.name,'entry',to_jsonb(e),'updated_at',s.updated_at,
   'corrected_amount',(select corrected.amount from public.dispute_events ev
      join public.ledger_entries corrected on corrected.id=(ev.metadata->>'corrected_entry_id')::uuid
      where ev.dispute_id=d.id and ev.event_type='partially_accepted'
      order by ev.created_at desc,ev.id desc limit 1),
   'messages',coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at,m.id)
     from public.dispute_messages m where m.dispute_id=d.id),'[]'::jsonb),
   'resolution',coalesce((select ev.metadata from public.dispute_events ev
     where ev.dispute_id=d.id and ev.event_type in ('accepted','partially_accepted','rejected')
     order by ev.created_at desc,ev.id desc limit 1),'{}'::jsonb))
 from public.disputes d join public.dispute_state s on s.dispute_id=d.id
 join public.ledger_entries e on e.id=d.entry_id
 join public.businesses b on b.id=d.business_id
 where private.is_customer_owner(d.customer_id)
   and private.can_customer_access_business_customer(e.business_customer_id)
   and (p_after is null or d.id>p_after)
 order by d.id limit p_limit;
end $$;
revoke all on function public.customer_disputes_page(uuid,integer) from public,anon;
grant execute on function public.customer_disputes_page(uuid,integer) to authenticated;

create or replace function private.command_add_dispute_message(
  p_dispute_id uuid,
  p_message text,
  p_client_request_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
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
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  select * into v_d from public.disputes where id=p_dispute_id;
  if not found then raise exception 'Dispute not found'; end if;
  select status into v_status from public.dispute_state where dispute_id=p_dispute_id for update;
  if not found then raise exception 'Dispute state not found'; end if;
  v_is_customer:=private.is_customer_owner(v_d.customer_id)
    and private.can_customer_access_business_customer((select business_customer_id from public.ledger_entries where id=v_d.entry_id));
  if not v_is_customer and not private.is_business_member(v_d.business_id,array['owner','admin','accountant','collector']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select result_entity_id into v_id from public.command_receipts
   where idempotency_key=v_request_id and command_type='add_dispute_message';
  if found then return v_id; end if;
  if v_status not in ('awaiting_merchant','awaiting_customer','open','escalated') then
    raise exception 'Dispute is already resolved' using errcode='55000';
  end if;
  insert into public.dispute_messages(dispute_id,sender_user_id,message)
    values(p_dispute_id,(select auth.uid()),trim(p_message)) returning id into v_id;
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
  if v_target is not null then
    perform private.enqueue_notification(v_target,'dispute_reply','رد جديد على الاعتراض','يوجد رد جديد في الاعتراض.','dispute',p_dispute_id,'{}'::jsonb);
  end if;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'add_dispute_message','accepted',v_id,jsonb_build_object('message_id',v_id,'dispute_id',p_dispute_id))
  on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;
revoke all on function public.customer_disputes_page(uuid,integer) from public,anon;
commit;

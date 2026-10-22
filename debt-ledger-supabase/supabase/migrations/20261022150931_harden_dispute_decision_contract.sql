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
  v_receipt public.command_receipts%rowtype;
  v_saved_amount numeric;
  v_customer_user uuid;
  v_event public.dispute_event_type;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_resolution is null or p_resolution not in ('accepted','partially_accepted','rejected') then
    raise exception 'Invalid resolution' using errcode='22023';
  end if;
  if p_resolution_note is null or length(trim(p_resolution_note)) not between 3 and 4000 then
    raise exception 'Resolution note must contain 3 to 4000 characters' using errcode='22023';
  end if;
  if p_resolution<>'partially_accepted' and p_corrected_amount is not null then
    raise exception 'Corrected amount is only allowed for an amount correction' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  select * into v_d from public.disputes where id=p_dispute_id;
  if not found then raise exception 'Dispute not found'; end if;
  select status into v_current from public.dispute_state where dispute_id=p_dispute_id for update;
  if not found then raise exception 'Dispute state not found'; end if;
  if not private.is_business_member(v_d.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select * into v_receipt from public.command_receipts
   where idempotency_key=v_request_id;
  if found then
    if p_resolution='partially_accepted' then
      select amount into v_saved_amount from public.ledger_entries
       where id=(v_receipt.result->>'corrected_entry_id')::uuid;
    end if;
    if v_receipt.command_type is distinct from 'resolve_dispute'
       or v_receipt.user_id is distinct from auth.uid()
       or v_receipt.result->>'dispute_id' is distinct from p_dispute_id::text
       or v_receipt.result->>'resolution' is distinct from p_resolution::text
       or coalesce(v_receipt.result->>'resolution_note',
         (select resolution_note from public.dispute_state where dispute_id=p_dispute_id))
           is distinct from trim(p_resolution_note)
       or v_saved_amount is distinct from p_corrected_amount then
      raise exception 'Request id was already used for a different dispute decision' using errcode='22023';
    end if;
    return v_receipt.result_entity_id;
  end if;
  if v_current not in ('open','awaiting_merchant','awaiting_customer','escalated') then
    raise exception 'Dispute is already resolved' using errcode='55000';
  end if;
  select * into v_entry from public.ledger_entries where id=v_d.entry_id;
  if not found then raise exception 'Disputed entry not found' using errcode='22023'; end if;
  if p_resolution='partially_accepted' and
     (p_corrected_amount is null or p_corrected_amount<=0 or p_corrected_amount>=v_entry.amount) then
    raise exception 'Corrected amount must be between zero and original amount' using errcode='22023';
  end if;
  if p_resolution in ('accepted','partially_accepted') then
    v_reversal:=private.command_reverse_ledger_entry(v_entry.id,left('تصحيح بسبب اعتراض: '||trim(p_resolution_note),500),gen_random_uuid(),true);
  end if;
  if p_resolution='partially_accepted' then
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
    values(v_request_id,(select auth.uid()),'resolve_dispute','accepted',coalesce(v_corrected,v_reversal),jsonb_build_object('dispute_id',p_dispute_id,'resolution',p_resolution,'resolution_note',trim(p_resolution_note),'corrected_amount',p_corrected_amount,'reversal_entry_id',v_reversal,'corrected_entry_id',v_corrected,'currency_code',v_entry.currency_code))
    on conflict(idempotency_key) do nothing;
  return coalesce(v_corrected,v_reversal);
end;
$$;

revoke execute on function private.command_resolve_dispute(uuid,public.dispute_current_status,text,numeric,uuid) from public,anon;
grant execute on function private.command_resolve_dispute(uuid,public.dispute_current_status,text,numeric,uuid) to authenticated;
revoke execute on function public.resolve_dispute(uuid,public.dispute_current_status,text,numeric,uuid) from public,anon;
grant execute on function public.resolve_dispute(uuid,public.dispute_current_status,text,numeric,uuid) to authenticated;

notify pgrst, 'reload schema';
commit;

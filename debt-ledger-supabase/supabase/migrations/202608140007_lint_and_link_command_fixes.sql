-- Debt Ledger MVP - Correct enum assignments and link-response command
begin;

create or replace function private.command_respond_link_request(p_request_id uuid,p_accept boolean)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_req public.customer_link_requests%rowtype; v_bc public.business_customers%rowtype; v_owner uuid;
begin
  select * into v_req from public.customer_link_requests where id=p_request_id for update;
  if not found or v_req.status<>'pending' or v_req.expires_at<now() then
    raise exception 'Invalid or expired request';
  end if;
  if not private.is_customer_owner(v_req.target_customer_id) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select * into v_bc from public.business_customers where id=v_req.business_customer_id;
  update public.customer_link_requests
  set status=case when p_accept then 'accepted'::public.link_request_status else 'rejected'::public.link_request_status end,
      responded_by_user_id=(select auth.uid()),responded_at=now(),updated_at=now()
  where id=p_request_id;
  update public.business_customers
  set link_status=case when p_accept then 'linked'::public.customer_link_status else 'rejected'::public.customer_link_status end
  where id=v_req.business_customer_id;
  select owner_user_id into v_owner from public.businesses where id=v_bc.business_id;
  perform private.enqueue_notification(
    v_owner,'link_request',case when p_accept then 'تم قبول الربط' else 'تم رفض الربط' end,
    case when p_accept then 'وافق العميل على ربط الحساب.' else 'رفض العميل طلب ربط الحساب.' end,
    'link_request',p_request_id,'{}'::jsonb
  );
end;
$$;

create or replace function private.command_create_ledger_entry(
  p_business_customer_id uuid,p_entry_type public.ledger_entry_type,p_amount numeric,p_description text,
  p_occurred_at timestamptz default now(),p_due_date date default null,p_external_reference text default null,
  p_client_request_id uuid default gen_random_uuid(),p_source_device_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_currency varchar(3); v_balance numeric(20,4); v_direction public.ledger_direction; v_id uuid; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  if p_entry_type not in ('opening_balance','debt','payment') then raise exception 'Use reverse_ledger_entry for reversals'; end if;
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then raise exception 'Business customer not found or archived'; end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant','cashier']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  select id into v_id from public.ledger_entries where business_id=v_bc.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
  if v_currency is null then raise exception 'Business is not active'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Amount must be positive'; end if;
  select coalesce(sum(case when direction='debit' then amount else -amount end),0) into v_balance from public.ledger_entries where business_customer_id=p_business_customer_id;
  if p_entry_type='payment' and p_amount>v_balance then raise exception 'Payment exceeds current balance'; end if;
  if v_bc.credit_limit is not null and p_entry_type in ('opening_balance','debt') and v_balance+p_amount>v_bc.credit_limit then raise exception 'Credit limit exceeded'; end if;
  v_direction:=case when p_entry_type='payment' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;
  insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,occurred_at,due_date,external_reference,client_request_id,source_device_id,created_by_user_id)
  values(v_bc.business_id,v_bc.id,v_bc.customer_id,p_entry_type,v_direction,p_amount,v_currency,trim(p_description),coalesce(p_occurred_at,now()),case when p_entry_type='debt' then p_due_date else null end,p_external_reference,v_request_id,p_source_device_id,(select auth.uid())) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,device_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),p_source_device_id,'create_ledger_entry','accepted',v_id,jsonb_build_object('entry_id',v_id)) on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function private.command_reverse_ledger_entry(p_entry_id uuid,p_reason text,p_client_request_id uuid default gen_random_uuid())
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_original public.ledger_entries%rowtype; v_id uuid; v_direction public.ledger_direction; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  select * into v_original from public.ledger_entries where id=p_entry_id for update;
  if not found or v_original.entry_type='reversal' then raise exception 'Invalid original entry'; end if;
  if not private.is_business_member(v_original.business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  select id into v_id from public.ledger_entries where business_id=v_original.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  if exists(select 1 from public.ledger_entries where reversal_of_entry_id=p_entry_id) then raise exception 'Entry already reversed'; end if;
  v_direction:=case when v_original.direction='debit' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;
  insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,occurred_at,reversal_of_entry_id,client_request_id,created_by_user_id)
  values(v_original.business_id,v_original.business_customer_id,v_original.customer_id,'reversal',v_direction,v_original.amount,v_original.currency_code,trim(p_reason),now(),v_original.id,v_request_id,(select auth.uid())) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'reverse_ledger_entry','accepted',v_id,jsonb_build_object('entry_id',v_id)) on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function private.command_resolve_dispute(p_dispute_id uuid,p_resolution public.dispute_current_status,p_resolution_note text,p_corrected_amount numeric default null)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_d public.disputes%rowtype; v_current public.dispute_current_status; v_entry public.ledger_entries%rowtype; v_reversal uuid; v_corrected uuid; v_customer_user uuid; v_event public.dispute_event_type;
begin
  select * into v_d from public.disputes where id=p_dispute_id;
  if not found then raise exception 'Dispute not found'; end if;
  select status into v_current from public.dispute_state where dispute_id=p_dispute_id for update;
  if not found then raise exception 'Dispute state not found'; end if;
  if not private.is_business_member(v_d.business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  if v_current not in ('open','awaiting_merchant','awaiting_customer','escalated') then raise exception 'Dispute is already resolved' using errcode='55000'; end if;
  if p_resolution not in ('accepted','partially_accepted','rejected') then raise exception 'Invalid resolution'; end if;
  select * into v_entry from public.ledger_entries where id=v_d.entry_id;
  if p_resolution in ('accepted','partially_accepted') then v_reversal:=private.command_reverse_ledger_entry(v_entry.id,'تصحيح بسبب اعتراض: '||trim(p_resolution_note),gen_random_uuid()); end if;
  if p_resolution='partially_accepted' then
    if p_corrected_amount is null or p_corrected_amount<=0 or p_corrected_amount>=v_entry.amount then raise exception 'Corrected amount must be between zero and original amount'; end if;
    v_corrected:=private.command_create_ledger_entry(v_entry.business_customer_id,v_entry.entry_type,p_corrected_amount,'قيمة مصححة للعملية '||v_entry.id::text,v_entry.occurred_at,v_entry.due_date,v_entry.external_reference,gen_random_uuid(),null);
  end if;
  update public.dispute_state set status=p_resolution,resolution_note=trim(p_resolution_note),resolved_by_user_id=(select auth.uid()),resolved_at=now() where dispute_id=p_dispute_id;
  update public.ledger_entry_state set dispute_status='resolved',last_event_at=now() where entry_id=v_entry.id;
  v_event:=case p_resolution when 'accepted' then 'accepted'::public.dispute_event_type when 'partially_accepted' then 'partially_accepted'::public.dispute_event_type else 'rejected'::public.dispute_event_type end;
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note,metadata) values(p_dispute_id,v_event,(select auth.uid()),trim(p_resolution_note),jsonb_build_object('reversal_entry_id',v_reversal,'corrected_entry_id',v_corrected));
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id,metadata) values(v_entry.id,v_entry.business_id,v_entry.customer_id,'dispute_resolved',(select auth.uid()),jsonb_build_object('resolution',p_resolution));
  select user_id into v_customer_user from public.customers where id=v_d.customer_id;
  if v_customer_user is not null then perform private.enqueue_notification(v_customer_user,'dispute_resolved','تمت معالجة الاعتراض','راجع نتيجة الاعتراض داخل التطبيق.','dispute',p_dispute_id,jsonb_build_object('resolution',p_resolution)); end if;
  return coalesce(v_corrected,v_reversal);
end;
$$;

commit;

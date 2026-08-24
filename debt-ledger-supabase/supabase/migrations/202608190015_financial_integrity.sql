-- Debt Ledger MVP - Financial integrity: unified locking, full idempotency, statement consistency,
-- AR reconciliation, journal_entry_status cleanup and description truncation.
-- Implements fix-plan/07-financial-integrity.md steps S1, S2, S4, S5, S6, S7, S8, S9.
--
-- Mandatory lock order for every financial command (decision D1):
--   1. advisory lock on the idempotency key  pg_advisory_xact_lock(hashtextextended(p_client_request_id::text, 0))
--   2. row lock on business_customers        ... for update   (serialization point for customer balances)
--   3. row lock on the original ledger_entries row            (reversal/dispute paths only, always after 2)
--   4. advisory lock on the entry id for the dispute cycle    pg_advisory_xact_lock(hashtextextended(p_entry_id::text, 0))
-- Never lock ledger_entries before business_customers.

begin;

-- ---------- S7 prerequisite: allow statement receipts (ninth command type) ----------
alter table public.command_receipts drop constraint command_receipts_command_type_check;
alter table public.command_receipts add constraint command_receipts_command_type_check check (
  command_type in (
    'create_ledger_entry','reverse_ledger_entry','confirm_ledger_entry','open_dispute',
    'add_dispute_message','resolve_dispute','apply_customer_discount','post_manual_journal',
    'create_statement'
  )
);

-- ---------- S1: reversal race fix (customer lock + active-dispute check + balance check) ----------
-- Signature is unchanged, so create-or-replace keeps existing grants.
create or replace function private.command_reverse_ledger_entry(
  p_entry_id uuid,
  p_reason text,
  p_client_request_id uuid default gen_random_uuid()
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_original public.ledger_entries%rowtype;
  v_bc public.business_customers%rowtype;
  v_balance numeric(20,4);
  v_allow_credit boolean;
  v_id uuid;
  v_direction public.ledger_direction;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  -- (1) Serialize retries of the same command under real concurrency.
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  -- Unlocked read to locate the customer row.
  select * into v_original from public.ledger_entries where id=p_entry_id;
  if not found or v_original.entry_type='reversal' then raise exception 'Invalid original entry'; end if;
  -- (2) Lock the customer row first — the same serialization point as entry creation.
  select * into v_bc from public.business_customers where id=v_original.business_customer_id for update;
  -- (3) Then lock the original entry.
  select * into v_original from public.ledger_entries where id=p_entry_id for update;
  -- (4) Shared dispute-cycle lock (open_dispute / confirm_ledger_entry / reverse_ledger_entry).
  perform pg_advisory_xact_lock(hashtextextended(p_entry_id::text,0));
  if not private.is_business_member(v_original.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  -- Idempotency after the locks.
  select id into v_id from public.ledger_entries
    where business_id=v_original.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  if exists(select 1 from public.ledger_entries where reversal_of_entry_id=p_entry_id) then
    raise exception 'Entry already reversed';
  end if;
  -- Never reverse while a dispute is active; the dispute resolution path performs the reversal itself.
  if exists(select 1 from public.disputes d join public.dispute_state ds on ds.dispute_id=d.id
            where d.entry_id=p_entry_id
              and ds.status in ('open','awaiting_merchant','awaiting_customer','escalated')) then
    raise exception 'Entry has an active dispute; resolve it first';
  end if;
  -- Reversing a debit subtracts from the customer balance: apply the same credit-balance policy
  -- (allow_customer_credit_balance) that governs overpayments.
  if v_original.direction='debit' then
    select coalesce(sum(case when direction='debit' then amount else -amount end),0)
      into v_balance from public.ledger_entries
     where business_customer_id=v_original.business_customer_id;
    select allow_customer_credit_balance into v_allow_credit
      from public.business_accounting_settings where business_id=v_original.business_id;
    if v_balance - v_original.amount < 0 and not coalesce(v_allow_credit,true) then
      raise exception 'Reversal would push the customer balance below zero';
    end if;
  end if;
  v_direction:=case when v_original.direction='debit' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;
  insert into public.ledger_entries(
    business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,
    occurred_at,reversal_of_entry_id,client_request_id,created_by_user_id
  ) values(
    v_original.business_id,v_original.business_customer_id,v_original.customer_id,'reversal',v_direction,
    v_original.amount,v_original.currency_code,trim(p_reason),now(),v_original.id,v_request_id,(select auth.uid())
  ) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'reverse_ledger_entry','accepted',v_id,jsonb_build_object('entry_id',v_id))
  on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

-- ---------- S5 + S6: confirm entry — shared dispute-cycle lock, reversed-entry guard, receipt ----------
drop function if exists public.confirm_ledger_entry(uuid,uuid);
drop function if exists private.command_confirm_ledger_entry(uuid,uuid);

create or replace function private.command_confirm_ledger_entry(
  p_entry_id uuid,
  p_device_id uuid default null,
  p_client_request_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_entry public.ledger_entries%rowtype;
  v_customer uuid;
  v_id uuid;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  select * into v_entry from public.ledger_entries where id=p_entry_id;
  if not found or not private.is_customer_owner(v_entry.customer_id)
     or not private.can_customer_access_business_customer(v_entry.business_customer_id) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  -- Same advisory lock open_dispute/reverse take: a confirm and a dispute can never both win.
  perform pg_advisory_xact_lock(hashtextextended(p_entry_id::text,0));
  select result_entity_id into v_id from public.command_receipts
   where idempotency_key=v_request_id and command_type='confirm_ledger_entry';
  if found then return v_id; end if;
  select private.current_customer_id() into v_customer;
  if exists(select 1 from public.entry_confirmations where entry_id=p_entry_id) then
    raise exception 'Entry already confirmed';
  end if;
  if exists(select 1 from public.ledger_entry_state where entry_id=p_entry_id and is_reversed) then
    raise exception 'Cannot confirm a reversed entry';
  end if;
  if exists(select 1 from public.disputes d join public.dispute_state ds on ds.dispute_id=d.id
            where d.entry_id=p_entry_id and ds.status in ('open','awaiting_merchant','awaiting_customer','escalated')) then
    raise exception 'Entry has an active dispute';
  end if;
  insert into public.entry_confirmations(entry_id,customer_id,confirmed_by_user_id,device_id)
    values(p_entry_id,v_customer,(select auth.uid()),p_device_id) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,device_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),p_device_id,'confirm_ledger_entry','accepted',v_id,jsonb_build_object('confirmation_id',v_id))
  on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function public.confirm_ledger_entry(
  p_entry_id uuid,
  p_device_id uuid default null,
  p_client_request_id uuid default null
)
returns uuid language sql set search_path=''
as $$ select private.command_confirm_ledger_entry(p_entry_id,p_device_id,p_client_request_id) $$;

-- ---------- S5 + S6: open dispute — confirmed/reversed guards + receipt ----------
drop function if exists public.open_dispute(uuid,public.dispute_reason,text);
drop function if exists private.command_open_dispute(uuid,public.dispute_reason,text);

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
  if exists(select 1 from public.entry_confirmations where entry_id=p_entry_id) then
    raise exception 'Entry is already confirmed';
  end if;
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

create or replace function public.open_dispute(
  p_entry_id uuid,
  p_reason public.dispute_reason,
  p_description text,
  p_client_request_id uuid default null
)
returns uuid language sql set search_path=''
as $$ select private.command_open_dispute(p_entry_id,p_reason,p_description,p_client_request_id) $$;

-- ---------- S6: dispute message receipt ----------
drop function if exists public.add_dispute_message(uuid,text);
drop function if exists private.command_add_dispute_message(uuid,text);

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
  if v_status not in ('awaiting_merchant','awaiting_customer','open') then
    raise exception 'Dispute is already resolved' using errcode='55000';
  end if;
  v_is_customer:=private.is_customer_owner(v_d.customer_id)
    and private.can_customer_access_business_customer((select business_customer_id from public.ledger_entries where id=v_d.entry_id));
  if not v_is_customer and not private.is_business_member(v_d.business_id,array['owner','admin','accountant','collector']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select result_entity_id into v_id from public.command_receipts
   where idempotency_key=v_request_id and command_type='add_dispute_message';
  if found then return v_id; end if;
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

create or replace function public.add_dispute_message(
  p_dispute_id uuid,
  p_message text,
  p_client_request_id uuid default null
)
returns uuid language sql set search_path=''
as $$ select private.command_add_dispute_message(p_dispute_id,p_message,p_client_request_id) $$;

-- ---------- S2 + S4 + S6: resolve dispute — discount branch, corrected-amount guard, ----------
-- truncated reversal reason, receipt. Defined after command_reverse_ledger_entry on purpose.
drop function if exists public.resolve_dispute(uuid,public.dispute_current_status,text,numeric);
drop function if exists private.command_resolve_dispute(uuid,public.dispute_current_status,text,numeric);

create or replace function private.command_resolve_dispute(
  p_dispute_id uuid,
  p_resolution public.dispute_current_status,
  p_resolution_note text,
  p_corrected_amount numeric default null,
  p_client_request_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
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
  if v_current not in ('open','awaiting_merchant','awaiting_customer','escalated') then
    raise exception 'Dispute is already resolved' using errcode='55000';
  end if;
  if p_resolution not in ('accepted','partially_accepted','rejected') then raise exception 'Invalid resolution'; end if;
  if p_resolution='rejected' and p_corrected_amount is not null then
    raise exception 'Corrected amount is only allowed for a partially accepted resolution';
  end if;
  -- Idempotent replay: result_entity_id may legitimately be null for a rejected dispute.
  select result_entity_id into v_replay from public.command_receipts
   where idempotency_key=v_request_id and command_type='resolve_dispute';
  if found then return v_replay; end if;
  select * into v_entry from public.ledger_entries where id=v_d.entry_id;
  if p_resolution in ('accepted','partially_accepted') then
    -- left(...,500): the reason column must never overflow the 500-char journal description budget.
    v_reversal:=private.command_reverse_ledger_entry(
      v_entry.id,left('تصحيح بسبب اعتراض: '||trim(p_resolution_note),500),gen_random_uuid());
  end if;
  if p_resolution='partially_accepted' then
    if p_corrected_amount is null or p_corrected_amount<=0 or p_corrected_amount>=v_entry.amount then
      raise exception 'Corrected amount must be between zero and original amount';
    end if;
    if v_entry.entry_type='discount' then
      -- command_create_ledger_entry rejects 'discount'; the discount command enforces the same roles.
      v_corrected:=private.command_apply_customer_discount(
        v_entry.business_customer_id,p_corrected_amount,
        'قيمة مصححة للعملية '||v_entry.id::text,v_entry.occurred_at,gen_random_uuid());
    else
      v_corrected:=private.command_create_ledger_entry(
        v_entry.business_customer_id,v_entry.entry_type,p_corrected_amount,
        'قيمة مصححة للعملية '||v_entry.id::text,v_entry.occurred_at,v_entry.due_date,v_entry.external_reference,gen_random_uuid(),null);
    end if;
  end if;
  update public.dispute_state set status=p_resolution,resolution_note=trim(p_resolution_note),resolved_by_user_id=(select auth.uid()),resolved_at=now()
    where dispute_id=p_dispute_id;
  update public.ledger_entry_state set dispute_status='resolved',last_event_at=now() where entry_id=v_entry.id;
  v_event:=case p_resolution when 'accepted' then 'accepted'::public.dispute_event_type when 'partially_accepted' then 'partially_accepted'::public.dispute_event_type else 'rejected'::public.dispute_event_type end;
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note,metadata)
    values(p_dispute_id,v_event,(select auth.uid()),trim(p_resolution_note),jsonb_build_object('reversal_entry_id',v_reversal,'corrected_entry_id',v_corrected));
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id,metadata)
    values(v_entry.id,v_entry.business_id,v_entry.customer_id,'dispute_resolved',(select auth.uid()),jsonb_build_object('resolution',p_resolution));
  select user_id into v_customer_user from public.customers where id=v_d.customer_id;
  if v_customer_user is not null then
    perform private.enqueue_notification(v_customer_user,'dispute_resolved','تمت معالجة الاعتراض','راجع نتيجة الاعتراض داخل التطبيق.','dispute',p_dispute_id,jsonb_build_object('resolution',p_resolution));
  end if;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'resolve_dispute','accepted',coalesce(v_corrected,v_reversal),
    jsonb_build_object('dispute_id',p_dispute_id,'resolution',p_resolution,'reversal_entry_id',v_reversal,'corrected_entry_id',v_corrected))
  on conflict(idempotency_key) do nothing;
  -- accepted -> reversal id; partially_accepted -> corrected entry id; rejected -> documented null.
  return coalesce(v_corrected,v_reversal);
end;
$$;

create or replace function public.resolve_dispute(
  p_dispute_id uuid,
  p_resolution public.dispute_current_status,
  p_resolution_note text,
  p_corrected_amount numeric default null,
  p_client_request_id uuid default null
)
returns uuid language sql set search_path=''
as $$ select private.command_resolve_dispute(p_dispute_id,p_resolution,p_resolution_note,p_corrected_amount,p_client_request_id) $$;

-- ---------- S6: manual journal receipt ----------
drop function if exists public.post_manual_journal(uuid,date,text,jsonb,text);
drop function if exists private.command_post_manual_journal(uuid,date,text,jsonb,text);

create or replace function private.command_post_manual_journal(
  p_business_id uuid,
  p_entry_date date,
  p_description text,
  p_lines jsonb,
  p_source_reference text default null,
  p_client_request_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_journal uuid;
  v_line jsonb;
  v_line_number smallint:=0;
  v_account uuid;
  v_debit numeric;
  v_credit numeric;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  if not private.is_business_member(p_business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select result_entity_id into v_journal from public.command_receipts
   where idempotency_key=v_request_id and command_type='post_manual_journal';
  if found then return v_journal; end if;
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<2 then
    raise exception 'Manual journal requires at least two lines';
  end if;
  perform private.assert_posting_period_open(p_business_id,p_entry_date);
  insert into public.journal_entries(business_id,source_type,source_reference,entry_date,description,posted_by_user_id)
    values(p_business_id,'manual_adjustment',p_source_reference,p_entry_date,trim(p_description),(select auth.uid())) returning id into v_journal;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_line_number:=v_line_number+1;
    v_account:=(v_line->>'account_id')::uuid;
    v_debit:=coalesce((v_line->>'debit_amount')::numeric,0);
    v_credit:=coalesce((v_line->>'credit_amount')::numeric,0);
    if not exists(select 1 from public.chart_of_accounts where id=v_account and business_id=p_business_id and allows_manual_posting and status='active') then
      raise exception 'Manual posting is not allowed to account %',v_account;
    end if;
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,description,debit_amount,credit_amount)
      values(v_journal,v_line_number,v_account,nullif(trim(v_line->>'description'),''),v_debit,v_credit);
  end loop;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'post_manual_journal','accepted',v_journal,jsonb_build_object('journal_entry_id',v_journal))
  on conflict(idempotency_key) do nothing;
  return v_journal;
end;
$$;

create or replace function public.post_manual_journal(
  p_business_id uuid,
  p_entry_date date,
  p_description text,
  p_lines jsonb,
  p_source_reference text default null,
  p_client_request_id uuid default null
)
returns uuid language sql set search_path=''
as $$ select private.command_post_manual_journal(p_business_id,p_entry_date,p_description,p_lines,p_source_reference,p_client_request_id) $$;

-- ---------- S7: statement generation — consistent snapshot via customer row locks + receipt ----------
-- A statement is a snapshot as of lock time; a later backdated entry never mutates an issued
-- statement (a new statement is required). This is intentional, documented behavior.
drop function if exists public.create_statement(public.statement_scope,uuid,timestamptz,timestamptz);
drop function if exists private.command_create_statement(public.statement_scope,uuid,timestamptz,timestamptz);

create or replace function private.command_create_statement(
  p_scope public.statement_scope,
  p_business_customer_id uuid default null,
  p_period_from timestamptz default (now()-interval '30 days'),
  p_period_to timestamptz default now(),
  p_client_request_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_customer uuid;
  v_business uuid;
  v_currency varchar(3);
  v_currency_count integer;
  v_opening numeric(20,4);
  v_debits numeric(20,4);
  v_credits numeric(20,4);
  v_statement uuid;
  v_code text;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  select result_entity_id into v_statement from public.command_receipts
   where idempotency_key=v_request_id and command_type='create_statement';
  if found then return v_statement; end if;
  if p_period_to<=p_period_from then raise exception 'Statement period end must be after its start'; end if;
  if p_scope='business_customer' then
    if p_business_customer_id is null then raise exception 'Business customer is required'; end if;
    -- Lock the customer row: no entry for this customer can commit while the snapshot is built.
    select customer_id,business_id into v_customer,v_business
      from public.business_customers where id=p_business_customer_id for update;
    if not found then raise exception 'Business customer not found'; end if;
    if not (private.is_business_member(v_business,array['owner','admin','accountant']::public.business_role[]) or private.can_customer_access_business_customer(p_business_customer_id)) then
      raise exception 'Not authorized' using errcode='42501';
    end if;
    select currency_code into v_currency from public.businesses where id=v_business;
  else
    if p_business_customer_id is not null then raise exception 'Consolidated statements cannot include a business customer'; end if;
    v_customer:=private.current_customer_id();
    if v_customer is null then raise exception 'Only a registered customer can create a consolidated statement' using errcode='42501'; end if;
    -- Lock every business_customers row of this customer in a fixed id order (deadlock-safe).
    perform 1 from public.business_customers where customer_id=v_customer order by id for update;
    select count(distinct currency_code),min(currency_code) into v_currency_count,v_currency
      from public.ledger_entries where customer_id=v_customer;
    if v_currency_count>1 then raise exception 'Consolidated statements require a single currency'; end if;
  end if;
  select coalesce(sum(case when direction='debit' then amount else -amount end),0)::numeric(20,4)
    into v_opening from public.ledger_entries
    where customer_id=v_customer and (p_scope='customer_consolidated' or business_customer_id=p_business_customer_id) and occurred_at<p_period_from;
  select coalesce(sum(case when direction='debit' then amount else 0 end),0)::numeric(20,4),
         coalesce(sum(case when direction='credit' then amount else 0 end),0)::numeric(20,4)
    into v_debits,v_credits from public.ledger_entries
    where customer_id=v_customer and (p_scope='customer_consolidated' or business_customer_id=p_business_customer_id)
      and occurred_at>=p_period_from and occurred_at<p_period_to;
  loop
    v_code:='ST-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    begin
      insert into public.statements(scope,business_id,business_customer_id,customer_id,period_from,period_to,currency_code,opening_balance,total_debits,total_credits,closing_balance,verification_code,generated_by_user_id)
      values(p_scope,v_business,p_business_customer_id,v_customer,p_period_from,p_period_to,v_currency,v_opening,v_debits,v_credits,v_opening+v_debits-v_credits,v_code,(select auth.uid()))
      returning id into v_statement;
      exit;
    exception when unique_violation then
      -- Retry only the extremely unlikely verification-code collision.
    end;
  end loop;
  insert into public.statement_items(statement_id,entry_id,item_order,occurred_at,description_snapshot,debit_amount,credit_amount,running_balance,confirmation_status)
  select v_statement,le.id,row_number() over(order by le.occurred_at,le.id),le.occurred_at,le.description,
    case when le.direction='debit' then le.amount else 0 end,
    case when le.direction='credit' then le.amount else 0 end,
    v_opening+sum(case when le.direction='debit' then le.amount else -le.amount end) over(order by le.occurred_at,le.id rows unbounded preceding),
    les.confirmation_status
  from public.ledger_entries le join public.ledger_entry_state les on les.entry_id=le.id
  where le.customer_id=v_customer and (p_scope='customer_consolidated' or le.business_customer_id=p_business_customer_id)
    and le.occurred_at>=p_period_from and le.occurred_at<p_period_to
  order by le.occurred_at,le.id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'create_statement','accepted',v_statement,jsonb_build_object('statement_id',v_statement,'verification_code',v_code))
  on conflict(idempotency_key) do nothing;
  return v_statement;
end;
$$;

create or replace function public.create_statement(
  p_scope public.statement_scope,
  p_business_customer_id uuid default null,
  p_period_from timestamptz default (now()-interval '30 days'),
  p_period_to timestamptz default now(),
  p_client_request_id uuid default null
)
returns uuid language sql set search_path=''
as $$ select private.command_create_statement(p_scope,p_business_customer_id,p_period_from,p_period_to,p_client_request_id) $$;

-- ---------- S4: truncate the generated journal description at 500 chars ----------
create or replace function private.post_ledger_entry_journal(p_ledger_entry_id uuid)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_entry public.ledger_entries%rowtype;
  v_journal uuid;
  v_original_journal uuid;
  v_settings public.business_accounting_settings%rowtype;
  v_line_no smallint:=0;
begin
  select * into v_entry from public.ledger_entries where id=p_ledger_entry_id;
  if not found then raise exception 'Ledger entry not found'; end if;
  select id into v_journal from public.journal_entries where source_ledger_entry_id=p_ledger_entry_id;
  if v_journal is not null then return v_journal; end if;
  perform private.assert_posting_period_open(v_entry.business_id,(v_entry.occurred_at at time zone (select timezone from public.businesses where id=v_entry.business_id))::date);
  select * into v_settings from public.business_accounting_settings where business_id=v_entry.business_id;
  if not found then raise exception 'Business accounting settings are not initialized'; end if;

  insert into public.journal_entries(business_id,source_ledger_entry_id,source_type,source_reference,entry_date,description,posted_by_user_id)
  values(v_entry.business_id,v_entry.id,'ledger_entry',v_entry.external_reference,(v_entry.occurred_at at time zone (select timezone from public.businesses where id=v_entry.business_id))::date,
    left('Ledger entry '||v_entry.entry_type::text||': '||v_entry.description,500),v_entry.created_by_user_id)
  returning id into v_journal;

  if v_entry.entry_type='reversal' then
    select id into v_original_journal from public.journal_entries where source_ledger_entry_id=v_entry.reversal_of_entry_id;
    if v_original_journal is null then
      perform private.post_ledger_entry_journal(v_entry.reversal_of_entry_id);
      select id into v_original_journal from public.journal_entries where source_ledger_entry_id=v_entry.reversal_of_entry_id;
    end if;
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount,credit_amount)
    select v_journal,row_number() over(order by line_number)::smallint,account_id,business_customer_id,'Reversal of ledger entry '||v_entry.reversal_of_entry_id::text,
      credit_amount,debit_amount
    from public.journal_entry_lines where journal_entry_id=v_original_journal order by line_number;
    return v_journal;
  end if;

  if v_entry.entry_type in ('opening_balance','debt') then
    v_line_no:=1;
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount)
    values(v_journal,v_line_no,v_settings.accounts_receivable_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
    v_line_no:=2;
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,credit_amount)
    values(v_journal,v_line_no,case when v_entry.entry_type='opening_balance' then v_settings.opening_balance_equity_account_id else v_settings.sales_revenue_account_id end,
      v_entry.business_customer_id,v_entry.description,v_entry.amount);
  elsif v_entry.entry_type='payment' then
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount)
    values(v_journal,1,v_settings.cash_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,credit_amount)
    values(v_journal,2,v_settings.accounts_receivable_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
  elsif v_entry.entry_type='discount' then
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount)
    values(v_journal,1,v_settings.sales_discount_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,credit_amount)
    values(v_journal,2,v_settings.accounts_receivable_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
  else
    raise exception 'Unsupported ledger entry type %',v_entry.entry_type;
  end if;
  return v_journal;
end;
$$;

-- ---------- S8: remove 'voided' from journal_entry_status + filter the trial balance ----------
-- Correction happens exclusively via reversal entries; 'voided' was dead weight (updates are blocked
-- by trg_journal_entries_immutable anyway). Fail loudly if any production row still uses it.
do $$
begin
  if exists(select 1 from public.journal_entries where status='voided') then
    raise exception 'Cannot drop journal_entry_status value voided: journal rows still reference it';
  end if;
end $$;

-- The trial-balance view depends on the status column; rebuild it after the type swap.
drop view if exists public.account_trial_balance;

create type public.journal_entry_status_new as enum ('posted');
alter table public.journal_entries alter column status drop default;
alter table public.journal_entries alter column status type public.journal_entry_status_new
  using status::text::public.journal_entry_status_new;
alter table public.journal_entries alter column status set default 'posted'::public.journal_entry_status_new;
drop type public.journal_entry_status;
alter type public.journal_entry_status_new rename to journal_entry_status;

create or replace view public.account_trial_balance
with (security_invoker=true)
as
select
  coa.business_id,coa.id as account_id,coa.account_code,coa.account_name,coa.account_class,coa.normal_balance,
  coalesce(sum(jel.debit_amount),0)::numeric(20,4) as total_debits,
  coalesce(sum(jel.credit_amount),0)::numeric(20,4) as total_credits,
  (coalesce(sum(jel.debit_amount),0)-coalesce(sum(jel.credit_amount),0))::numeric(20,4) as signed_balance,
  case when coa.normal_balance='debit' then greatest(coalesce(sum(jel.debit_amount),0)-coalesce(sum(jel.credit_amount),0),0)
       else greatest(coalesce(sum(jel.credit_amount),0)-coalesce(sum(jel.debit_amount),0),0) end::numeric(20,4) as normal_balance_amount
from public.chart_of_accounts coa
left join (
  public.journal_entry_lines jel
  join public.journal_entries je on je.id=jel.journal_entry_id and je.status='posted'
) on jel.account_id=coa.id
group by coa.business_id,coa.id,coa.account_code,coa.account_name,coa.account_class,coa.normal_balance;

-- ---------- S9: automated AR reconciliation between the operational ledger and the GL ----------
-- Source of truth: operational customer balances derive from ledger_entries; the GL accounts-
-- receivable control account is its accounting mirror. Any deviation is surfaced here and is
-- expected to be detected within 24h by a scheduled run of private.run_ar_reconciliation().
create or replace view public.reconciliation_customer_ar
with (security_invoker=true)
as
select
  bc.id as business_customer_id,
  bc.business_id,
  coalesce((select sum(case when le.direction='debit' then le.amount else -le.amount end)
            from public.ledger_entries le where le.business_customer_id=bc.id),0)::numeric(20,4) as operational_balance,
  coalesce((select sum(jel.debit_amount)-sum(jel.credit_amount)
            from public.journal_entry_lines jel
            join public.journal_entries je on je.id=jel.journal_entry_id and je.status='posted'
            join public.business_accounting_settings s
              on s.business_id=bc.business_id and s.accounts_receivable_account_id=jel.account_id
            where jel.business_customer_id=bc.id),0)::numeric(20,4) as gl_ar_balance
from public.business_customers bc;

create or replace function private.run_ar_reconciliation()
returns integer
language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
  insert into private.dead_letter_jobs(job_type,source_id,error,payload)
  select 'ar_reconciliation',
         r.business_customer_id::text,
         'Operational customer balance differs from the GL accounts-receivable balance',
         jsonb_build_object(
           'business_id',r.business_id,
           'operational_balance',r.operational_balance,
           'gl_ar_balance',r.gl_ar_balance,
           'deviation',r.operational_balance-r.gl_ar_balance,
           'detected_at',now()
         )
    from public.reconciliation_customer_ar r
   where r.operational_balance<>r.gl_ar_balance
  on conflict(job_type,source_id) do update
    set error=excluded.error,
        payload=excluded.payload,
        created_at=now(),
        resolved_at=null;
  get diagnostics v_count=row_count;

  -- Auto-resolve deviations that have disappeared since the previous run.
  update private.dead_letter_jobs d
     set resolved_at=now()
   where d.job_type='ar_reconciliation'
     and d.resolved_at is null
     and not exists(
       select 1 from public.reconciliation_customer_ar r
        where r.business_customer_id::text=d.source_id
          and r.operational_balance<>r.gl_ar_balance
     );
  return v_count;
end;
$$;

-- ---------- Grants (dropped functions lose their grants; re-grant the new signatures) ----------
grant execute on function public.confirm_ledger_entry(uuid,uuid,uuid) to authenticated;
grant execute on function public.open_dispute(uuid,public.dispute_reason,text,uuid) to authenticated;
grant execute on function public.add_dispute_message(uuid,text,uuid) to authenticated;
grant execute on function public.resolve_dispute(uuid,public.dispute_current_status,text,numeric,uuid) to authenticated;
grant execute on function public.post_manual_journal(uuid,date,text,jsonb,text,uuid) to authenticated;
grant execute on function public.create_statement(public.statement_scope,uuid,timestamptz,timestamptz,uuid) to authenticated;
grant execute on function private.command_confirm_ledger_entry(uuid,uuid,uuid) to authenticated;
grant execute on function private.command_open_dispute(uuid,public.dispute_reason,text,uuid) to authenticated;
grant execute on function private.command_add_dispute_message(uuid,text,uuid) to authenticated;
grant execute on function private.command_resolve_dispute(uuid,public.dispute_current_status,text,numeric,uuid) to authenticated;
grant execute on function private.command_post_manual_journal(uuid,date,text,jsonb,text,uuid) to authenticated;
grant execute on function private.command_create_statement(public.statement_scope,uuid,timestamptz,timestamptz,uuid) to authenticated;
grant select on public.account_trial_balance to authenticated;
grant select on public.reconciliation_customer_ar to authenticated;
revoke all on function private.run_ar_reconciliation() from public,anon,authenticated;
grant execute on function private.run_ar_reconciliation() to service_role;

commit;

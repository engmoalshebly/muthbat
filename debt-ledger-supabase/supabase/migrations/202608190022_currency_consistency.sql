-- Currency consistency hardening.
-- The ledger is strictly multi-currency: every operational and accounting
-- projection is grouped by currency and no RPC silently falls back to base
-- currency when a currency was explicitly selected.

begin;

-- Reject duplicate additional currencies as well as malformed/base duplicates.
create or replace function private.is_valid_additional_currencies(
  p_currencies text[],
  p_base_currency text
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select
    cardinality(coalesce(p_currencies, '{}'::text[])) =
      cardinality(array(select distinct c from unnest(coalesce(p_currencies, '{}'::text[])) as c))
    and not exists (
      select 1
      from unnest(coalesce(p_currencies, '{}'::text[])) as c
      where c !~ '^[A-Z]{3}$' or c = upper(p_base_currency)
    )
$$;

alter table public.businesses drop constraint if exists businesses_additional_currencies_iso;
alter table public.businesses
  add constraint businesses_additional_currencies_iso
  check (private.is_valid_additional_currencies(additional_currencies, currency_code));

drop function if exists public.create_business(text,text,varchar,varchar,text,text);
drop function if exists private.command_create_business(text,text,varchar,varchar,text,text);

create or replace function private.command_create_business(
  p_name text,
  p_business_type text,
  p_currency_code varchar,
  p_country_code varchar default 'YE',
  p_city text default null,
  p_address text default null,
  p_additional_currencies text[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare v_user uuid := (select auth.uid()); v_business uuid; v_base varchar(3);
begin
  if v_user is null then raise exception 'Authentication required' using errcode='28000'; end if;
  v_base:=upper(trim(p_currency_code));
  if v_base !~ '^[A-Z]{3}$' then raise exception 'Invalid base currency' using errcode='22023'; end if;
  if not private.is_valid_additional_currencies(p_additional_currencies,v_base) then
    raise exception 'Invalid additional currencies' using errcode='22023';
  end if;
  insert into public.businesses(owner_user_id,name,business_type,currency_code,additional_currencies,country_code,city,address)
  values(v_user,trim(p_name),trim(p_business_type),v_base,coalesce(p_additional_currencies,'{}'),upper(p_country_code),p_city,p_address)
  returning id into v_business;
  insert into public.business_members(business_id,user_id,role,status)
  values(v_business,v_user,'owner','active');
  return v_business;
end;
$$;

create or replace function public.create_business(
  p_name text,
  p_business_type text,
  p_currency_code varchar,
  p_country_code varchar default 'YE',
  p_city text default null,
  p_address text default null,
  p_additional_currencies text[] default '{}'
)
returns uuid language sql set search_path=''
as $$ select private.command_create_business(p_name,p_business_type,p_currency_code,p_country_code,p_city,p_address,p_additional_currencies) $$;

-- Replace both legacy overloads with a single named contract that accepts an
-- optional currency as the final argument. Keeping it last preserves old
-- positional internal callers while allowing the Flutter client to be explicit.
drop function if exists public.create_ledger_entry(
  uuid,public.ledger_entry_type,numeric,text,text,text,text,text,text,
  timestamptz,date,text,uuid,uuid
);
drop function if exists private.command_create_ledger_entry(
  uuid,public.ledger_entry_type,numeric,text,timestamptz,date,text,uuid,uuid,
  text,text,text,text,text
);

create or replace function private.command_create_ledger_entry(
  p_business_customer_id uuid,
  p_entry_type public.ledger_entry_type,
  p_amount numeric,
  p_description text,
  p_occurred_at timestamptz default now(),
  p_due_date date default null,
  p_external_reference text default null,
  p_client_request_id uuid default gen_random_uuid(),
  p_source_device_id uuid default null,
  p_category text default 'goods',
  p_payment_method text default 'cash',
  p_reference_number text default null,
  p_bank_or_agent_name text default null,
  p_attachment_url text default null,
  p_currency_code varchar default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bc public.business_customers%rowtype;
  v_currency varchar(3);
  v_balance numeric(20,4);
  v_direction public.ledger_direction;
  v_id uuid;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_allow_credit boolean;
  v_category public.ledger_entry_category;
  v_payment_method public.ledger_payment_method;
begin
  if p_entry_type not in ('opening_balance','debt','payment') then
    raise exception 'Use apply_customer_discount or reverse_ledger_entry for this entry type';
  end if;
  if p_category is null or p_category not in ('goods','service','cash','transfer','discount','other') then
    raise exception 'Invalid category: %', p_category using errcode='22023';
  end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','cheque','offset','discount','other') then
    raise exception 'Invalid payment method: %', p_payment_method using errcode='22023';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be positive';
  end if;
  if p_amount <> round(p_amount, 4) then
    raise exception 'Amount supports at most 4 decimal places';
  end if;
  if length(trim(coalesce(p_description,''))) < 2 then
    raise exception 'Description is required';
  end if;

  v_category := p_category::public.ledger_entry_category;
  v_payment_method := p_payment_method::public.ledger_payment_method;

  select * into v_bc
    from public.business_customers
   where id = p_business_customer_id
   for update;
  if not found or v_bc.is_archived then
    raise exception 'Business customer not found or archived';
  end if;
  if not private.is_business_member(v_bc.business_id, array['owner','admin','accountant','cashier']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;

  select id into v_id
    from public.ledger_entries
   where business_id = v_bc.business_id and client_request_id = v_request_id;
  if v_id is not null then return v_id; end if;

  select currency_code into v_currency
    from public.businesses
   where id = v_bc.business_id and status = 'active';
  if v_currency is null then raise exception 'Business is not active'; end if;

  if p_currency_code is not null then
    if upper(trim(p_currency_code)) !~ '^[A-Z]{3}$' then
      raise exception 'Currency not allowed for this business' using errcode='22023';
    end if;
    v_currency := upper(trim(p_currency_code));
    if not private.business_allows_currency(v_bc.business_id, v_currency) then
      raise exception 'Currency not allowed for this business' using errcode='22023';
    end if;
  end if;

  select coalesce(sum(case when direction='debit' then amount else -amount end),0)
    into v_balance
    from public.ledger_entries
   where business_customer_id = p_business_customer_id
     and currency_code = v_currency;
  select allow_customer_credit_balance into v_allow_credit
    from public.business_accounting_settings
   where business_id = v_bc.business_id;
  if p_entry_type = 'payment' and p_amount > v_balance and not coalesce(v_allow_credit,true) then
    raise exception 'Payment exceeds current balance';
  end if;
  if v_bc.credit_limit is not null
     and p_entry_type in ('opening_balance','debt')
     and v_balance + p_amount > v_bc.credit_limit then
    raise exception 'Credit limit exceeded';
  end if;

  v_direction := case when p_entry_type='payment' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;
  insert into public.ledger_entries(
    business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,
    category,payment_method,reference_number,bank_or_agent_name,attachment_url,
    description,occurred_at,due_date,external_reference,client_request_id,source_device_id,created_by_user_id
  ) values (
    v_bc.business_id,v_bc.id,v_bc.customer_id,p_entry_type,v_direction,p_amount,v_currency,
    v_category,v_payment_method,nullif(trim(p_reference_number),''),nullif(trim(p_bank_or_agent_name),''),nullif(trim(p_attachment_url),''),
    left(trim(p_description),500),coalesce(p_occurred_at,now()),case when p_entry_type='debt' then p_due_date else null end,
    p_external_reference,v_request_id,p_source_device_id,(select auth.uid())
  ) returning id into v_id;

  insert into public.command_receipts(idempotency_key,user_id,device_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),p_source_device_id,'create_ledger_entry','accepted',v_id,
         jsonb_build_object('entry_id',v_id,'currency_code',v_currency))
  on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function public.create_ledger_entry(
  p_business_customer_id uuid,
  p_entry_type public.ledger_entry_type,
  p_amount numeric,
  p_description text,
  p_category text default 'goods',
  p_payment_method text default 'cash',
  p_reference_number text default null,
  p_bank_or_agent_name text default null,
  p_attachment_url text default null,
  p_occurred_at timestamptz default now(),
  p_due_date date default null,
  p_external_reference text default null,
  p_client_request_id uuid default gen_random_uuid(),
  p_source_device_id uuid default null,
  p_currency_code varchar default null
)
returns uuid
language sql
set search_path = ''
as $$
  select private.command_create_ledger_entry(
    p_business_customer_id := p_business_customer_id,
    p_entry_type := p_entry_type,
    p_amount := p_amount,
    p_description := p_description,
    p_occurred_at := p_occurred_at,
    p_due_date := p_due_date,
    p_external_reference := p_external_reference,
    p_client_request_id := p_client_request_id,
    p_source_device_id := p_source_device_id,
    p_category := p_category,
    p_payment_method := p_payment_method,
    p_reference_number := p_reference_number,
    p_bank_or_agent_name := p_bank_or_agent_name,
    p_attachment_url := p_attachment_url,
    p_currency_code := p_currency_code
  )
$$;

-- Reversal policy must be evaluated in the original entry currency. Dispute
-- resolution is the only trusted internal path allowed to reverse an active
-- dispute; the public reversal command remains blocked.
drop function if exists private.command_reverse_ledger_entry(uuid,text,uuid);
create or replace function private.command_reverse_ledger_entry(
  p_entry_id uuid,
  p_reason text,
  p_client_request_id uuid default gen_random_uuid(),
  p_allow_active_dispute boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_original public.ledger_entries%rowtype;
  v_bc public.business_customers%rowtype;
  v_balance numeric(20,4);
  v_allow_credit boolean;
  v_id uuid;
  v_direction public.ledger_direction;
  v_request_id uuid := coalesce(p_client_request_id,gen_random_uuid());
begin
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  select * into v_original from public.ledger_entries where id=p_entry_id;
  if not found or v_original.entry_type='reversal' then raise exception 'Invalid original entry'; end if;
  select * into v_bc from public.business_customers where id=v_original.business_customer_id for update;
  select * into v_original from public.ledger_entries where id=p_entry_id for update;
  perform pg_advisory_xact_lock(hashtextextended(p_entry_id::text,0));
  if not private.is_business_member(v_original.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select id into v_id from public.ledger_entries
   where business_id=v_original.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  if exists(select 1 from public.ledger_entries where reversal_of_entry_id=p_entry_id) then
    raise exception 'Entry already reversed';
  end if;
  if not p_allow_active_dispute and exists(
    select 1 from public.disputes d join public.dispute_state ds on ds.dispute_id=d.id
     where d.entry_id=p_entry_id and ds.status in ('open','awaiting_merchant','awaiting_customer','escalated')
  ) then
    raise exception 'Entry has an active dispute; resolve it first';
  end if;
  if v_original.direction='debit' then
    select coalesce(sum(case when direction='debit' then amount else -amount end),0)
      into v_balance from public.ledger_entries
     where business_customer_id=v_original.business_customer_id
       and currency_code=v_original.currency_code;
    select allow_customer_credit_balance into v_allow_credit
      from public.business_accounting_settings where business_id=v_original.business_id;
    if v_balance-v_original.amount < 0 and not coalesce(v_allow_credit,true) then
      raise exception 'Reversal would push the customer balance below zero';
    end if;
  end if;
  v_direction:=case when v_original.direction='debit' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;
  insert into public.ledger_entries(
    business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,
    occurred_at,reversal_of_entry_id,client_request_id,created_by_user_id
  ) values(
    v_original.business_id,v_original.business_customer_id,v_original.customer_id,'reversal',v_direction,
    v_original.amount,v_original.currency_code,left(trim(p_reason),500),now(),v_original.id,v_request_id,(select auth.uid())
  ) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'reverse_ledger_entry','accepted',v_id,
         jsonb_build_object('entry_id',v_id,'currency_code',v_original.currency_code))
  on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

-- Partial dispute corrections preserve the original entry currency.
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
  if v_current not in ('open','awaiting_merchant','awaiting_customer','escalated') then
    raise exception 'Dispute is already resolved' using errcode='55000';
  end if;
  if p_resolution not in ('accepted','partially_accepted','rejected') then raise exception 'Invalid resolution'; end if;
  if p_resolution='rejected' and p_corrected_amount is not null then
    raise exception 'Corrected amount is only allowed for a partially accepted resolution';
  end if;
  select result_entity_id into v_replay from public.command_receipts
   where idempotency_key=v_request_id and command_type='resolve_dispute';
  if found then return v_replay; end if;
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

-- Per-currency trial balance. A missing account still receives a base-currency
-- zero row, while posted journal currencies produce additional rows.
drop view if exists public.account_trial_balance;
create view public.account_trial_balance
with (security_invoker=true)
as
select
  coa.business_id, coa.id as account_id, coa.account_code, coa.account_name,
  coa.account_class, coa.normal_balance,
  coalesce(jel.currency_code,b.currency_code) as currency_code,
  coalesce(sum(jel.debit_amount),0)::numeric(20,4) as total_debits,
  coalesce(sum(jel.credit_amount),0)::numeric(20,4) as total_credits,
  (coalesce(sum(jel.debit_amount),0)-coalesce(sum(jel.credit_amount),0))::numeric(20,4) as signed_balance,
  case when coa.normal_balance='debit'
       then greatest(coalesce(sum(jel.debit_amount),0)-coalesce(sum(jel.credit_amount),0),0)
       else greatest(coalesce(sum(jel.credit_amount),0)-coalesce(sum(jel.debit_amount),0),0)
  end::numeric(20,4) as normal_balance_amount
from public.chart_of_accounts coa
join public.businesses b on b.id=coa.business_id
left join (
  public.journal_entry_lines jel
  join public.journal_entries je on je.id=jel.journal_entry_id and je.status='posted'
) on jel.account_id=coa.id
group by coa.business_id,coa.id,coa.account_code,coa.account_name,coa.account_class,coa.normal_balance,
         coalesce(jel.currency_code,b.currency_code);

-- Per-currency AR reconciliation. The source key includes currency so one
-- customer's YER drift cannot overwrite its SAR drift.
drop view if exists public.reconciliation_customer_ar;
create view public.reconciliation_customer_ar
with (security_invoker=true)
as
with currency_scope as (
  select bc.id as business_customer_id,bc.business_id,b.currency_code
    from public.business_customers bc join public.businesses b on b.id=bc.business_id
  union
  select le.business_customer_id,le.business_id,le.currency_code
    from public.ledger_entries le
)
select
  cs.business_customer_id,cs.business_id,cs.currency_code,
  coalesce((select sum(case when le.direction='debit' then le.amount else -le.amount end)
              from public.ledger_entries le
             where le.business_customer_id=cs.business_customer_id and le.currency_code=cs.currency_code),0)::numeric(20,4) as operational_balance,
  coalesce((select sum(jel.debit_amount)-sum(jel.credit_amount)
              from public.journal_entry_lines jel
              join public.journal_entries je on je.id=jel.journal_entry_id and je.status='posted'
              join public.business_accounting_settings s on s.business_id=cs.business_id and s.accounts_receivable_account_id=jel.account_id
             where jel.business_customer_id=cs.business_customer_id and jel.currency_code=cs.currency_code),0)::numeric(20,4) as gl_ar_balance
from currency_scope cs;

create or replace function private.run_ar_reconciliation()
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare v_count integer;
begin
  insert into private.dead_letter_jobs(job_type,source_id,error,payload)
  select 'ar_reconciliation',r.business_customer_id::text||':'||r.currency_code,
         'Operational customer balance differs from the GL accounts-receivable balance',
         jsonb_build_object('business_id',r.business_id,'currency_code',r.currency_code,
           'operational_balance',r.operational_balance,'gl_ar_balance',r.gl_ar_balance,
           'deviation',r.operational_balance-r.gl_ar_balance,'detected_at',now())
    from public.reconciliation_customer_ar r
   where r.operational_balance<>r.gl_ar_balance
  on conflict(job_type,source_id) do update set error=excluded.error,payload=excluded.payload,created_at=now(),resolved_at=null;
  get diagnostics v_count=row_count;
  update private.dead_letter_jobs d set resolved_at=now()
   where d.job_type='ar_reconciliation' and d.resolved_at is null
     and not exists(
       select 1 from public.reconciliation_customer_ar r
        where d.source_id=r.business_customer_id::text||':'||r.currency_code
          and r.operational_balance<>r.gl_ar_balance
     );
  return v_count;
end;
$$;

-- Statements always represent exactly one currency. Consolidated statements
-- may choose a currency explicitly; otherwise they are rejected when mixed.
drop function if exists public.create_statement(public.statement_scope,uuid,timestamptz,timestamptz,uuid);
drop function if exists private.command_create_statement(public.statement_scope,uuid,timestamptz,timestamptz,uuid);

create or replace function private.command_create_statement(
  p_scope public.statement_scope,
  p_business_customer_id uuid default null,
  p_period_from timestamptz default (now()-interval '30 days'),
  p_period_to timestamptz default now(),
  p_client_request_id uuid default null,
  p_currency_code varchar default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_customer uuid; v_business uuid; v_currency varchar(3); v_currency_count integer;
  v_opening numeric(20,4); v_debits numeric(20,4); v_credits numeric(20,4);
  v_statement uuid; v_code text; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text,0));
  select result_entity_id into v_statement from public.command_receipts
   where idempotency_key=v_request_id and command_type='create_statement';
  if found then return v_statement; end if;
  if p_period_to<=p_period_from then raise exception 'Statement period end must be after its start'; end if;

  if p_scope='business_customer' then
    if p_business_customer_id is null then raise exception 'Business customer is required'; end if;
    select customer_id,business_id into v_customer,v_business from public.business_customers where id=p_business_customer_id for update;
    if not found then raise exception 'Business customer not found'; end if;
    if not (private.is_business_member(v_business,array['owner','admin','accountant']::public.business_role[]) or private.can_customer_access_business_customer(p_business_customer_id)) then
      raise exception 'Not authorized' using errcode='42501';
    end if;
    select currency_code into v_currency from public.businesses where id=v_business;
    if p_currency_code is not null then
      if upper(trim(p_currency_code)) !~ '^[A-Z]{3}$' or not private.business_allows_currency(v_business,upper(trim(p_currency_code))) then
        raise exception 'Currency not allowed for this business' using errcode='22023';
      end if;
      v_currency:=upper(trim(p_currency_code));
    end if;
  else
    if p_business_customer_id is not null then raise exception 'Consolidated statements cannot include a business customer'; end if;
    v_customer:=private.current_customer_id();
    if v_customer is null then raise exception 'Only a registered customer can create a consolidated statement' using errcode='42501'; end if;
    perform 1 from public.business_customers where customer_id=v_customer order by id for update;
    if p_currency_code is null then
      select count(distinct currency_code),min(currency_code) into v_currency_count,v_currency from public.ledger_entries where customer_id=v_customer;
      if v_currency_count>1 then raise exception 'Consolidated statements require an explicit currency'; end if;
    else
      if upper(trim(p_currency_code)) !~ '^[A-Z]{3}$' then raise exception 'Invalid statement currency' using errcode='22023'; end if;
      v_currency:=upper(trim(p_currency_code));
      if not exists(select 1 from public.ledger_entries where customer_id=v_customer and currency_code=v_currency) then
        raise exception 'Customer has no entries in the requested currency';
      end if;
    end if;
  end if;

  select coalesce(sum(case when direction='debit' then amount else -amount end),0)::numeric(20,4) into v_opening
    from public.ledger_entries where customer_id=v_customer and (p_scope='customer_consolidated' or business_customer_id=p_business_customer_id)
      and currency_code=v_currency and occurred_at<p_period_from;
  select coalesce(sum(case when direction='debit' then amount else 0 end),0)::numeric(20,4),
         coalesce(sum(case when direction='credit' then amount else 0 end),0)::numeric(20,4) into v_debits,v_credits
    from public.ledger_entries where customer_id=v_customer and (p_scope='customer_consolidated' or business_customer_id=p_business_customer_id)
      and currency_code=v_currency and occurred_at>=p_period_from and occurred_at<p_period_to;

  loop
    v_code:='ST-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    begin
      insert into public.statements(scope,business_id,business_customer_id,customer_id,period_from,period_to,currency_code,opening_balance,total_debits,total_credits,closing_balance,verification_code,generated_by_user_id)
      values(p_scope,v_business,p_business_customer_id,v_customer,p_period_from,p_period_to,v_currency,v_opening,v_debits,v_credits,v_opening+v_debits-v_credits,v_code,(select auth.uid())) returning id into v_statement;
      exit;
    exception when unique_violation then null;
    end;
  end loop;
  insert into public.statement_items(statement_id,entry_id,item_order,occurred_at,description_snapshot,debit_amount,credit_amount,running_balance,confirmation_status)
  select v_statement,le.id,row_number() over(order by le.occurred_at,le.id),le.occurred_at,le.description,
    case when le.direction='debit' then le.amount else 0 end,case when le.direction='credit' then le.amount else 0 end,
    v_opening+sum(case when le.direction='debit' then le.amount else -le.amount end) over(order by le.occurred_at,le.id rows unbounded preceding),les.confirmation_status
    from public.ledger_entries le join public.ledger_entry_state les on les.entry_id=le.id
   where le.customer_id=v_customer and (p_scope='customer_consolidated' or le.business_customer_id=p_business_customer_id)
     and le.currency_code=v_currency and le.occurred_at>=p_period_from and le.occurred_at<p_period_to
   order by le.occurred_at,le.id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'create_statement','accepted',v_statement,jsonb_build_object('statement_id',v_statement,'verification_code',v_code,'currency_code',v_currency))
  on conflict(idempotency_key) do nothing;
  return v_statement;
end;
$$;

create or replace function public.create_statement(
  p_scope public.statement_scope,
  p_business_customer_id uuid default null,
  p_period_from timestamptz default (now()-interval '30 days'),
  p_period_to timestamptz default now(),
  p_client_request_id uuid default null,
  p_currency_code varchar default null
)
returns uuid language sql set search_path=''
as $$ select private.command_create_statement(p_scope,p_business_customer_id,p_period_from,p_period_to,p_client_request_id,p_currency_code) $$;

grant execute on function public.create_ledger_entry(uuid,public.ledger_entry_type,numeric,text,text,text,text,text,text,timestamptz,date,text,uuid,uuid,varchar) to authenticated;
grant execute on function private.command_create_ledger_entry(uuid,public.ledger_entry_type,numeric,text,timestamptz,date,text,uuid,uuid,text,text,text,text,text,varchar) to authenticated;
grant execute on function public.create_business(text,text,varchar,varchar,text,text,text[]) to authenticated;
grant execute on function private.command_create_business(text,text,varchar,varchar,text,text,text[]) to authenticated;
grant execute on function public.create_statement(public.statement_scope,uuid,timestamptz,timestamptz,uuid,varchar) to authenticated;
grant execute on function private.command_create_statement(public.statement_scope,uuid,timestamptz,timestamptz,uuid,varchar) to authenticated;
grant select on public.account_trial_balance,public.reconciliation_customer_ar to authenticated;
revoke all on function private.run_ar_reconciliation() from public,anon,authenticated;
grant execute on function private.run_ar_reconciliation() to service_role;

commit;

-- Migration: 202608190014_rpc_contract_extensions.sql
-- Description: RPC contract unification (fix-plan 02, phase zero):
--   1) Extend private.command_create_ledger_entry + public.create_ledger_entry with the
--      category / payment-method / reference / attachment parameters the Flutter client
--      already sends (merchant_repository.dart). Currency stays derived from the business
--      (no p_currency_code in v1 — fix-plan.md decision 1 + 02 §1.2-أ).
--   2) Extend apply_customer_discount with an optional p_currency_code (default null =
--      business currency), approved by fix-plan.md §3.ب step 2 (01-10 = 05-2). When
--      provided it must be the business currency or a member of additional_currencies.
--   3) Add public.api_contract_version() returning '1.0.0' (02 §4.2).
-- Backward compatibility: the first parameters keep the exact order/types of the previous
-- signatures, so existing positional internal callers (e.g. command_resolve_dispute) and
-- older PostgREST named-argument clients keep working; old overloads are dropped so the
-- public contract surface stays a single function per name (02 §1.1).
-- Dependency: runs after 202608190013 (multi_currency_redo) which owns the category /
-- payment-method enum column conversion and businesses.additional_currencies. The
-- idempotent guards below only make partial/legacy states safe; they do not replace 0013.

begin;

-- ---------- 0. Idempotent guards (defensive; owned canonically by 0013) ----------

-- Category / payment-method enums (same values as 0013 / fix-plan 01 §3.2).
do $$ begin
  create type public.ledger_entry_category as enum ('goods','service','cash','transfer','discount','other');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.ledger_payment_method as enum ('cash','bank_transfer','cheque','offset','discount','other');
exception when duplicate_object then null; end $$;

-- Category / payment / attachment columns (originally 0012, canonically re-added by 0013).
alter table public.ledger_entries
  add column if not exists category text default 'goods',
  add column if not exists payment_method text default 'cash',
  add column if not exists reference_number text,
  add column if not exists bank_or_agent_name text,
  add column if not exists attachment_url text;

-- Per-business allowed extra currencies (canonically added by 0013 with its ISO check).
alter table public.businesses
  add column if not exists additional_currencies text[] not null default '{}';

-- ---------- 1. create_ledger_entry: drop old overloads, publish extended signature ----------

drop function if exists public.create_ledger_entry(uuid,public.ledger_entry_type,numeric,text,timestamptz,date,text,uuid,uuid);
drop function if exists private.command_create_ledger_entry(uuid,public.ledger_entry_type,numeric,text,timestamptz,date,text,uuid,uuid);

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
  p_attachment_url text default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_bc public.business_customers%rowtype;
  v_currency varchar(3);
  v_balance numeric(20,4);
  v_direction public.ledger_direction;
  v_id uuid;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
  v_allow_credit boolean;
  v_category public.ledger_entry_category;
  v_payment_method public.ledger_payment_method;
begin
  if p_entry_type not in ('opening_balance','debt','payment') then
    raise exception 'Use apply_customer_discount or reverse_ledger_entry for this entry type';
  end if;

  -- Category / payment-method discipline: reject garbage instead of storing it (02 step 7).
  if p_category is null or p_category not in ('goods','service','cash','transfer','discount','other') then
    raise exception 'Invalid category: %', p_category using errcode='22023';
  end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','cheque','offset','discount','other') then
    raise exception 'Invalid payment method: %', p_payment_method using errcode='22023';
  end if;
  v_category := p_category::public.ledger_entry_category;
  v_payment_method := p_payment_method::public.ledger_payment_method;

  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then raise exception 'Business customer not found or archived'; end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant','cashier']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;

  -- Soft idempotency: same client_request_id returns the original entry.
  select id into v_id from public.ledger_entries where business_id=v_bc.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;

  -- Currency is always derived from the business in v1 (no client-supplied currency).
  select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
  if v_currency is null then raise exception 'Business is not active'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Amount must be positive'; end if;

  -- Balance and credit-limit checks are evaluated per currency (fix-plan 01 §3.5).
  select coalesce(sum(case when direction='debit' then amount else -amount end),0) into v_balance
    from public.ledger_entries
   where business_customer_id=p_business_customer_id and currency_code=v_currency;
  select allow_customer_credit_balance into v_allow_credit from public.business_accounting_settings where business_id=v_bc.business_id;
  if p_entry_type='payment' and p_amount>v_balance and not coalesce(v_allow_credit,true) then
    raise exception 'Payment exceeds current balance';
  end if;
  if v_bc.credit_limit is not null and p_entry_type in ('opening_balance','debt') and v_balance+p_amount>v_bc.credit_limit then
    raise exception 'Credit limit exceeded';
  end if;

  v_direction:=case when p_entry_type='payment' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;

  insert into public.ledger_entries(
    business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,
    category,payment_method,reference_number,bank_or_agent_name,attachment_url,
    description,occurred_at,due_date,external_reference,client_request_id,source_device_id,created_by_user_id
  ) values(
    v_bc.business_id,v_bc.id,v_bc.customer_id,p_entry_type,v_direction,p_amount,v_currency,
    v_category,v_payment_method,nullif(trim(p_reference_number),''),nullif(trim(p_bank_or_agent_name),''),nullif(trim(p_attachment_url),''),
    trim(p_description),coalesce(p_occurred_at,now()),case when p_entry_type='debt' then p_due_date else null end,
    p_external_reference,v_request_id,p_source_device_id,(select auth.uid())
  ) returning id into v_id;

  insert into public.command_receipts(idempotency_key,user_id,device_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),p_source_device_id,'create_ledger_entry','accepted',v_id,jsonb_build_object('entry_id',v_id))
  on conflict(idempotency_key) do nothing;

  return v_id;
end;
$$;

-- Public wrapper: parameter names/order follow the binding contract 02 §1.1-4 exactly
-- (PostgREST matches by name). Currency is intentionally absent in v1.
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
  p_source_device_id uuid default null
)
returns uuid language sql set search_path=''
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
    p_attachment_url := p_attachment_url
  )
$$;

-- ---------- 2. apply_customer_discount: optional currency (01-10 = 05-2) ----------

drop function if exists public.apply_customer_discount(uuid,numeric,text,timestamptz,uuid);
drop function if exists private.command_apply_customer_discount(uuid,numeric,text,timestamptz,uuid);

create or replace function private.command_apply_customer_discount(
  p_business_customer_id uuid,
  p_amount numeric,
  p_description text,
  p_occurred_at timestamptz default now(),
  p_client_request_id uuid default gen_random_uuid(),
  p_currency_code varchar default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_bc public.business_customers%rowtype;
  v_currency varchar(3);
  v_balance numeric(20,4);
  v_id uuid;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then raise exception 'Business customer not found or archived'; end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;

  select id into v_id from public.ledger_entries where business_id=v_bc.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;

  if p_amount is null or p_amount<=0 then raise exception 'Discount amount must be positive'; end if;

  -- Currency: default is the business currency; an explicit currency must be allowed
  -- for the business (base currency or additional_currencies — dormant in v1).
  if p_currency_code is null then
    select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
    if v_currency is null then raise exception 'Business is not active'; end if;
  else
    -- Validate the full supplied value before the varchar(3) assignment truncates it.
    if upper(trim(p_currency_code)) !~ '^[A-Z]{3}$' then
      raise exception 'Currency not allowed for this business' using errcode='22023';
    end if;
    v_currency:=upper(trim(p_currency_code));
    if not exists (
      select 1 from public.businesses b
       where b.id=v_bc.business_id and b.status='active'
         and (b.currency_code=v_currency or v_currency = any(b.additional_currencies))
    ) then
      raise exception 'Currency not allowed for this business' using errcode='22023';
    end if;
  end if;

  -- The outstanding balance is evaluated in the discount's own currency.
  select coalesce(sum(case when direction='debit' then amount else -amount end),0) into v_balance
    from public.ledger_entries
   where business_customer_id=p_business_customer_id and currency_code=v_currency;
  if v_balance<=0 or p_amount>v_balance then
    raise exception 'Discount cannot exceed the outstanding debit balance';
  end if;

  insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,occurred_at,client_request_id,created_by_user_id)
  values(v_bc.business_id,v_bc.id,v_bc.customer_id,'discount','credit',p_amount,v_currency,trim(p_description),coalesce(p_occurred_at,now()),v_request_id,(select auth.uid()))
  returning id into v_id;

  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'apply_customer_discount','accepted',v_id,jsonb_build_object('entry_id',v_id))
  on conflict(idempotency_key) do nothing;

  return v_id;
end;
$$;

create or replace function public.apply_customer_discount(
  p_business_customer_id uuid,
  p_amount numeric,
  p_description text,
  p_occurred_at timestamptz default now(),
  p_client_request_id uuid default gen_random_uuid(),
  p_currency_code varchar default null
)
returns uuid language sql set search_path=''
as $$ select private.command_apply_customer_discount(p_business_customer_id,p_amount,p_description,p_occurred_at,p_client_request_id,p_currency_code) $$;

-- ---------- 3. Contract version (02 §4.2) ----------

create or replace function public.api_contract_version()
returns text language sql stable set search_path=''
as $$ select '1.0.0'::text $$;

-- ---------- 4. Grants (same pattern as 0003 / 0010) ----------

grant execute on function public.create_ledger_entry(uuid,public.ledger_entry_type,numeric,text,text,text,text,text,text,timestamptz,date,text,uuid,uuid) to authenticated;
grant execute on function public.apply_customer_discount(uuid,numeric,text,timestamptz,uuid,varchar) to authenticated;
grant execute on function public.api_contract_version() to authenticated;
grant execute on function private.command_create_ledger_entry(uuid,public.ledger_entry_type,numeric,text,timestamptz,date,text,uuid,uuid,text,text,text,text,text) to authenticated;
grant execute on function private.command_apply_customer_discount(uuid,numeric,text,timestamptz,uuid,varchar) to authenticated;

commit;

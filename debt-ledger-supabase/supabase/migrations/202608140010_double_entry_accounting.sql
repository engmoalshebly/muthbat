-- Debt Ledger MVP - Professional double-entry accounting layer
-- Adds a business chart of accounts and automatically journals every ledger event.

begin;

create type public.account_class as enum ('asset','liability','equity','revenue','expense');
create type public.account_normal_balance as enum ('debit','credit');
create type public.accounting_account_status as enum ('active','inactive');
create type public.accounting_period_status as enum ('open','closed');
create type public.journal_entry_status as enum ('posted','voided');

create table public.chart_of_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  parent_account_id uuid references public.chart_of_accounts(id) on delete restrict,
  account_code varchar(12) not null check (account_code ~ '^[0-9]{4,12}$'),
  account_name text not null check (char_length(trim(account_name)) between 2 and 160),
  account_class public.account_class not null,
  normal_balance public.account_normal_balance not null,
  is_control_account boolean not null default false,
  allows_manual_posting boolean not null default true,
  status public.accounting_account_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,account_code),
  check (
    (account_class in ('asset','expense') and normal_balance='debit')
    or (account_class in ('liability','equity','revenue') and normal_balance='credit')
  )
);

create table public.business_accounting_settings (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  accounts_receivable_account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  cash_account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  sales_revenue_account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  sales_discount_account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  opening_balance_equity_account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  allow_customer_credit_balance boolean not null default true,
  updated_at timestamptz not null default now(),
  check (accounts_receivable_account_id <> cash_account_id),
  check (sales_revenue_account_id <> sales_discount_account_id)
);

create table public.accounting_periods (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  period_start date not null,
  period_end date not null,
  status public.accounting_period_status not null default 'open',
  closed_by_user_id uuid references auth.users(id) on delete restrict,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,period_start,period_end),
  check(period_end >= period_start),
  check((status='closed' and closed_by_user_id is not null and closed_at is not null) or status='open')
);

create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  entry_number bigint generated always as identity unique,
  business_id uuid not null references public.businesses(id) on delete restrict,
  source_ledger_entry_id uuid unique references public.ledger_entries(id) on delete restrict,
  source_type text not null check(source_type in ('ledger_entry','manual_adjustment')),
  source_reference text,
  entry_date date not null,
  description text not null check(char_length(trim(description)) between 2 and 500),
  status public.journal_entry_status not null default 'posted',
  posted_by_user_id uuid not null references auth.users(id) on delete restrict,
  posted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check((source_type='ledger_entry' and source_ledger_entry_id is not null) or (source_type='manual_adjustment' and source_ledger_entry_id is null))
);

create table public.journal_entry_lines (
  id bigint generated always as identity primary key,
  journal_entry_id uuid not null references public.journal_entries(id) on delete restrict,
  line_number smallint not null check(line_number > 0),
  account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  business_customer_id uuid references public.business_customers(id) on delete restrict,
  description text,
  debit_amount numeric(20,4) not null default 0 check(debit_amount >= 0),
  credit_amount numeric(20,4) not null default 0 check(credit_amount >= 0),
  created_at timestamptz not null default now(),
  unique(journal_entry_id,line_number),
  check((debit_amount > 0 and credit_amount=0) or (credit_amount > 0 and debit_amount=0))
);

create index idx_chart_of_accounts_business_class on public.chart_of_accounts(business_id,account_class,account_code);
create index idx_journal_entries_business_date on public.journal_entries(business_id,entry_date desc,entry_number desc);
create index idx_journal_lines_account on public.journal_entry_lines(account_id,journal_entry_id);
create index idx_journal_lines_business_customer on public.journal_entry_lines(business_customer_id,journal_entry_id) where business_customer_id is not null;

alter table public.chart_of_accounts enable row level security;
alter table public.business_accounting_settings enable row level security;
alter table public.accounting_periods enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_entry_lines enable row level security;

revoke all on public.chart_of_accounts,public.business_accounting_settings,public.accounting_periods,public.journal_entries,public.journal_entry_lines from anon,authenticated;
grant select on public.chart_of_accounts,public.business_accounting_settings,public.accounting_periods,public.journal_entries,public.journal_entry_lines to authenticated;

create policy chart_of_accounts_select_member on public.chart_of_accounts for select to authenticated
using(private.is_business_member(business_id,null));
create policy accounting_settings_select_member on public.business_accounting_settings for select to authenticated
using(private.is_business_member(business_id,null));
create policy accounting_periods_select_member on public.accounting_periods for select to authenticated
using(private.is_business_member(business_id,null));
create policy journal_entries_select_member on public.journal_entries for select to authenticated
using(private.is_business_member(business_id,null));
create policy journal_lines_select_member on public.journal_entry_lines for select to authenticated
using(exists(select 1 from public.journal_entries je where je.id=journal_entry_lines.journal_entry_id and private.is_business_member(je.business_id,null)));

create trigger trg_chart_of_accounts_updated_at before update on public.chart_of_accounts
for each row execute function private.set_updated_at();
create trigger trg_business_accounting_settings_updated_at before update on public.business_accounting_settings
for each row execute function private.set_updated_at();
create trigger trg_accounting_periods_updated_at before update on public.accounting_periods
for each row execute function private.set_updated_at();
create trigger trg_journal_entries_immutable before update or delete on public.journal_entries
for each row execute function private.prevent_update_delete();
create trigger trg_journal_entry_lines_immutable before update or delete on public.journal_entry_lines
for each row execute function private.prevent_update_delete();

create or replace function private.initialize_business_chart(p_business_id uuid)
returns void
language plpgsql security definer set search_path=''
as $$
declare
  v_ar uuid; v_cash uuid; v_sales uuid; v_discount uuid; v_opening uuid;
begin
  insert into public.chart_of_accounts(business_id,account_code,account_name,account_class,normal_balance,is_control_account,allows_manual_posting)
  values
    (p_business_id,'1000','Cash on hand','asset','debit',false,true),
    (p_business_id,'1100','Accounts receivable','asset','debit',true,false),
    (p_business_id,'3100','Opening balance equity','equity','credit',false,false),
    (p_business_id,'4000','Sales revenue','revenue','credit',false,true),
    (p_business_id,'5100','Sales discounts','expense','debit',false,true)
  on conflict(business_id,account_code) do nothing;

  select id into v_cash from public.chart_of_accounts where business_id=p_business_id and account_code='1000';
  select id into v_ar from public.chart_of_accounts where business_id=p_business_id and account_code='1100';
  select id into v_opening from public.chart_of_accounts where business_id=p_business_id and account_code='3100';
  select id into v_sales from public.chart_of_accounts where business_id=p_business_id and account_code='4000';
  select id into v_discount from public.chart_of_accounts where business_id=p_business_id and account_code='5100';
  insert into public.business_accounting_settings(
    business_id,accounts_receivable_account_id,cash_account_id,sales_revenue_account_id,sales_discount_account_id,opening_balance_equity_account_id
  ) values(p_business_id,v_ar,v_cash,v_sales,v_discount,v_opening)
  on conflict(business_id) do nothing;
end;
$$;

create or replace function private.after_business_create_accounting()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  perform private.initialize_business_chart(new.id);
  return new;
end;
$$;

create trigger trg_after_business_create_accounting after insert on public.businesses
for each row execute function private.after_business_create_accounting();

create or replace function private.assert_posting_period_open(p_business_id uuid,p_entry_date date)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  if exists(select 1 from public.accounting_periods where business_id=p_business_id and status='closed' and p_entry_date between period_start and period_end) then
    raise exception 'Accounting period is closed for %',p_entry_date using errcode='55000';
  end if;
end;
$$;

create or replace function private.validate_journal_entry_line()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_business uuid; v_account_business uuid; v_ar uuid; v_bc_business uuid;
begin
  select business_id into v_business from public.journal_entries where id=new.journal_entry_id;
  select business_id into v_account_business from public.chart_of_accounts where id=new.account_id and status='active';
  if v_business is null or v_account_business is null or v_account_business<>v_business then
    raise exception 'Journal line account must be active and belong to the journal business';
  end if;
  if new.business_customer_id is not null then
    select business_id into v_bc_business from public.business_customers where id=new.business_customer_id;
    if v_bc_business is null or v_bc_business<>v_business then raise exception 'Journal line customer must belong to the journal business'; end if;
  end if;
  select accounts_receivable_account_id into v_ar from public.business_accounting_settings where business_id=v_business;
  if new.account_id=v_ar and new.business_customer_id is null then
    raise exception 'Accounts receivable lines require a business customer dimension';
  end if;
  return new;
end;
$$;

create trigger trg_validate_journal_entry_line before insert on public.journal_entry_lines
for each row execute function private.validate_journal_entry_line();

create or replace function private.assert_journal_entry_balanced()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_journal uuid:=coalesce(new.journal_entry_id,old.journal_entry_id); v_debits numeric; v_credits numeric; v_count integer;
begin
  select count(*),coalesce(sum(debit_amount),0),coalesce(sum(credit_amount),0)
    into v_count,v_debits,v_credits from public.journal_entry_lines where journal_entry_id=v_journal;
  if v_count<2 or v_debits<>v_credits then
    raise exception 'Journal entry % is not balanced (debits %, credits %)',v_journal,v_debits,v_credits using errcode='23514';
  end if;
  return null;
end;
$$;

create constraint trigger trg_journal_entry_balanced
after insert or update or delete on public.journal_entry_lines
deferrable initially deferred for each row execute function private.assert_journal_entry_balanced();

create or replace function private.assert_posted_journal_has_lines()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  if new.status='posted' and not exists(select 1 from public.journal_entry_lines where journal_entry_id=new.id) then
    raise exception 'Posted journal entry requires lines' using errcode='23514';
  end if;
  return null;
end;
$$;

create constraint trigger trg_posted_journal_has_lines
after insert on public.journal_entries
deferrable initially deferred for each row execute function private.assert_posted_journal_has_lines();

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
    'Ledger entry '||v_entry.entry_type::text||': '||v_entry.description,v_entry.created_by_user_id)
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

create or replace function private.after_ledger_entry_accounting()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  perform private.post_ledger_entry_journal(new.id);
  return new;
end;
$$;

create trigger trg_after_ledger_entry_accounting after insert on public.ledger_entries
for each row execute function private.after_ledger_entry_accounting();

alter table public.ledger_entries drop constraint ledger_entries_check;
alter table public.ledger_entries add constraint ledger_entries_check check (
  (entry_type in ('opening_balance','debt') and direction='debit' and reversal_of_entry_id is null)
  or (entry_type in ('payment','discount') and direction='credit' and reversal_of_entry_id is null)
  or (entry_type='reversal' and reversal_of_entry_id is not null)
);

create or replace function private.validate_ledger_entry_insert()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_currency text; v_original public.ledger_entries%rowtype;
begin
  select * into v_bc from public.business_customers where id=new.business_customer_id;
  if not found or v_bc.business_id<>new.business_id or v_bc.customer_id<>new.customer_id then raise exception 'Ledger tenant/customer mismatch'; end if;
  select currency_code into v_currency from public.businesses where id=new.business_id and status='active';
  if v_currency is null or v_currency<>new.currency_code then raise exception 'Currency or business status mismatch'; end if;
  if not private.is_business_member(new.business_id,array['owner','admin','accountant','cashier']::public.business_role[]) then raise exception 'Not authorized to create ledger entries' using errcode='42501'; end if;
  if new.entry_type in ('opening_balance','discount') and not private.is_business_member(new.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception '% requires an elevated role',new.entry_type using errcode='42501';
  end if;
  if new.entry_type='reversal' then
    select * into v_original from public.ledger_entries where id=new.reversal_of_entry_id for update;
    if not found or v_original.business_id<>new.business_id or v_original.customer_id<>new.customer_id then raise exception 'Invalid reversal target'; end if;
    if v_original.entry_type='reversal' then raise exception 'A reversal cannot reverse another reversal'; end if;
    if new.amount<>v_original.amount or new.currency_code<>v_original.currency_code then raise exception 'Reversal must match original amount and currency'; end if;
    if new.direction=v_original.direction then raise exception 'Reversal direction must be opposite'; end if;
  end if;
  return new;
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
declare v_bc public.business_customers%rowtype; v_currency varchar(3); v_balance numeric(20,4); v_direction public.ledger_direction; v_id uuid; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid()); v_allow_credit boolean;
begin
  if p_entry_type not in ('opening_balance','debt','payment') then raise exception 'Use apply_customer_discount or reverse_ledger_entry for this entry type'; end if;
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then raise exception 'Business customer not found or archived'; end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant','cashier']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  select id into v_id from public.ledger_entries where business_id=v_bc.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
  if v_currency is null then raise exception 'Business is not active'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Amount must be positive'; end if;
  select coalesce(sum(case when direction='debit' then amount else -amount end),0) into v_balance from public.ledger_entries where business_customer_id=p_business_customer_id;
  select allow_customer_credit_balance into v_allow_credit from public.business_accounting_settings where business_id=v_bc.business_id;
  if p_entry_type='payment' and p_amount>v_balance and not coalesce(v_allow_credit,true) then raise exception 'Payment exceeds current balance'; end if;
  if v_bc.credit_limit is not null and p_entry_type in ('opening_balance','debt') and v_balance+p_amount>v_bc.credit_limit then raise exception 'Credit limit exceeded'; end if;
  v_direction:=case when p_entry_type='payment' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;
  insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,occurred_at,due_date,external_reference,client_request_id,source_device_id,created_by_user_id)
  values(v_bc.business_id,v_bc.id,v_bc.customer_id,p_entry_type,v_direction,p_amount,v_currency,trim(p_description),coalesce(p_occurred_at,now()),case when p_entry_type='debt' then p_due_date else null end,p_external_reference,v_request_id,p_source_device_id,(select auth.uid())) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,device_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),p_source_device_id,'create_ledger_entry','accepted',v_id,jsonb_build_object('entry_id',v_id)) on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function private.command_apply_customer_discount(
  p_business_customer_id uuid,p_amount numeric,p_description text,p_occurred_at timestamptz default now(),p_client_request_id uuid default gen_random_uuid()
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_currency varchar(3); v_balance numeric(20,4); v_id uuid; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then raise exception 'Business customer not found or archived'; end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  select id into v_id from public.ledger_entries where business_id=v_bc.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Discount amount must be positive'; end if;
  select coalesce(sum(case when direction='debit' then amount else -amount end),0) into v_balance from public.ledger_entries where business_customer_id=p_business_customer_id;
  if v_balance<=0 or p_amount>v_balance then raise exception 'Discount cannot exceed the outstanding debit balance'; end if;
  select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
  if v_currency is null then raise exception 'Business is not active'; end if;
  insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,occurred_at,client_request_id,created_by_user_id)
  values(v_bc.business_id,v_bc.id,v_bc.customer_id,'discount','credit',p_amount,v_currency,trim(p_description),coalesce(p_occurred_at,now()),v_request_id,(select auth.uid())) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'apply_customer_discount','accepted',v_id,jsonb_build_object('entry_id',v_id)) on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function public.apply_customer_discount(
  p_business_customer_id uuid,p_amount numeric,p_description text,p_occurred_at timestamptz default now(),p_client_request_id uuid default gen_random_uuid()
)
returns uuid language sql set search_path=''
as $$ select private.command_apply_customer_discount(p_business_customer_id,p_amount,p_description,p_occurred_at,p_client_request_id) $$;

create or replace function private.command_post_manual_journal(
  p_business_id uuid,p_entry_date date,p_description text,p_lines jsonb,p_source_reference text default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_journal uuid; v_line jsonb; v_line_number smallint:=0; v_account uuid; v_debit numeric; v_credit numeric;
begin
  if not private.is_business_member(p_business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<2 then raise exception 'Manual journal requires at least two lines'; end if;
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
  return v_journal;
end;
$$;

create or replace function public.post_manual_journal(
  p_business_id uuid,p_entry_date date,p_description text,p_lines jsonb,p_source_reference text default null
)
returns uuid language sql set search_path=''
as $$ select private.command_post_manual_journal(p_business_id,p_entry_date,p_description,p_lines,p_source_reference) $$;

create or replace function private.command_close_accounting_period(p_business_id uuid,p_period_start date,p_period_end date)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if not private.is_business_member(p_business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  if p_period_end<p_period_start then raise exception 'Period end must be on or after period start'; end if;
  if exists(select 1 from public.accounting_periods where business_id=p_business_id and status='closed' and daterange(period_start,period_end,'[]') && daterange(p_period_start,p_period_end,'[]')) then
    raise exception 'Accounting period overlaps a closed period';
  end if;
  insert into public.accounting_periods(business_id,period_start,period_end,status,closed_by_user_id,closed_at)
  values(p_business_id,p_period_start,p_period_end,'closed',(select auth.uid()),now()) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.close_accounting_period(p_business_id uuid,p_period_start date,p_period_end date)
returns uuid language sql set search_path=''
as $$ select private.command_close_accounting_period(p_business_id,p_period_start,p_period_end) $$;

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
left join public.journal_entry_lines jel on jel.account_id=coa.id
group by coa.business_id,coa.id,coa.account_code,coa.account_name,coa.account_class,coa.normal_balance;

create or replace view public.business_customer_account_positions
with (security_invoker=true)
as
select
  bc.id as business_customer_id,bc.business_id,bc.customer_id,bc.local_display_name,b.currency_code,
  coalesce(sum(case when le.direction='debit' then le.amount else -le.amount end),0)::numeric(20,4) as receivable_signed_balance,
  greatest(coalesce(sum(case when le.direction='debit' then le.amount else -le.amount end),0),0)::numeric(20,4) as amount_customer_owes,
  greatest(-coalesce(sum(case when le.direction='debit' then le.amount else -le.amount end),0),0)::numeric(20,4) as amount_business_owes_customer
from public.business_customers bc
join public.businesses b on b.id=bc.business_id
left join public.ledger_entries le on le.business_customer_id=bc.id
group by bc.id,bc.business_id,bc.customer_id,bc.local_display_name,b.currency_code;

-- Existing businesses receive the default chart and every historical ledger item gains one balanced journal entry.
do $$
declare v_business record; v_entry record;
begin
  for v_business in select id from public.businesses loop
    perform private.initialize_business_chart(v_business.id);
  end loop;
  for v_entry in select id from public.ledger_entries order by created_at,id loop
    perform private.post_ledger_entry_journal(v_entry.id);
  end loop;
end $$;

grant select on public.account_trial_balance,public.business_customer_account_positions to authenticated;
grant execute on function public.apply_customer_discount(uuid,numeric,text,timestamptz,uuid) to authenticated;
grant execute on function public.post_manual_journal(uuid,date,text,jsonb,text) to authenticated;
grant execute on function public.close_accounting_period(uuid,date,date) to authenticated;
grant usage on schema private to authenticated;
grant execute on function private.command_apply_customer_discount(uuid,numeric,text,timestamptz,uuid) to authenticated;
grant execute on function private.command_post_manual_journal(uuid,date,text,jsonb,text) to authenticated;
grant execute on function private.command_close_accounting_period(uuid,date,date) to authenticated;

commit;



-- Migration: 202608190013_multi_currency_redo.sql
-- Description: Multi-currency redo (replaces broken 202608180012) — per-business allowed
--   currency list, corrected customer_currency_balances, debit/credit balance trigger,
--   currency columns in the double-entry layer, currency-grouped balance views,
--   reconciliation. Design: fix-plan/01-migration-012.md (Option ج — per-business
--   currency allowlist, strict separation, no FX conversion). Default
--   additional_currencies='{}' keeps single-currency behavior identical to today
--   (dormant capability, fix-plan.md decision 1).
-- The whole file runs in one transaction (fixes 01-low-5).
--
-- Ownership boundaries (parallel migrations 0014/0015 run AFTER this one and only drop
-- pre-0013 signatures; redefining these here would leave ambiguous overloads):
--   * public/private (command_)create_ledger_entry, apply_customer_discount → 0014.
--   * (command_)post_manual_journal, (command_)create_statement,
--     private.post_ledger_entry_journal, public.account_trial_balance      → 0015.
-- Currency safety for the 0015-owned journal writers is enforced here via defensive
-- BEFORE INSERT fill triggers (section 6), so their currency-unaware bodies still
-- satisfy the new NOT NULL columns with the correct currency.

begin;

-- ============================================================================
-- 0. Idempotent cleanup block (covers partial/full deployments of broken 0012)
-- ============================================================================
-- Emergency: the broken trigger ('in'/'out' vs debit/credit) paralyzes ledger inserts.
drop trigger if exists trg_ledger_entry_currency_balance on public.ledger_entries;
drop function if exists private.trig_update_customer_currency_balance();
-- 0012's unauthorized public command function. Entry creation stays on the original
-- path only (private.command_create_ledger_entry via public.create_ledger_entry,
-- extended by 0014) — no new public entry-creation function is ever created here.
drop function if exists public.command_create_ledger_entry(uuid,public.ledger_entry_type,numeric,varchar,text,text,text,text,text,timestamptz,date,text,uuid,text);
-- Derived table (plus its policies/indexes/triggers) — rebuilt below and refilled
-- from ledger_entries, so no real data is lost. CASCADE drops its policies, which
-- also covers environments where the policies were never created.
drop table if exists public.customer_currency_balances cascade;
-- ledger_entries category/payment_method/reference_number/bank_or_agent_name/attachment_url
-- columns (if partially applied) are kept and converted safely in section 2 below.

-- ============================================================================
-- 1. Per-business allowed currency list (dormant: default '{}' = single currency)
-- ============================================================================
alter table public.businesses
  add column if not exists additional_currencies text[] not null default '{}';

-- CHECK constraints cannot contain subqueries, so the ISO/duplicate validation lives
-- in a truly immutable helper.
create or replace function private.is_valid_additional_currencies(p_currencies text[], p_base_currency text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select not exists (
    select 1
    from unnest(coalesce(p_currencies, '{}'::text[])) as c
    where c !~ '^[A-Z]{3}$' or c = p_base_currency
  )
$$;

alter table public.businesses drop constraint if exists businesses_additional_currencies_iso;
alter table public.businesses
  add constraint businesses_additional_currencies_iso
  check (private.is_valid_additional_currencies(additional_currencies, currency_code));

-- Membership helper used by the validation trigger (and by 0014/0015 commands).
create or replace function private.business_allows_currency(p_business_id uuid, p_currency text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.businesses b
    where b.id = p_business_id
      and b.status = 'active'
      and (b.currency_code = p_currency or p_currency = any(b.additional_currencies))
  )
$$;

-- ============================================================================
-- 2. Categorization columns — disciplined enums instead of free text
--    (values match what the mobile app actually sends, incl. 'discount')
-- ============================================================================
do $$ begin
  create type public.ledger_entry_category as enum ('goods','service','cash','transfer','discount','other');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.ledger_payment_method as enum ('cash','bank_transfer','cheque','offset','discount','other');
exception when duplicate_object then null; end $$;

-- Columns may already exist as plain text from a partial 0012 deployment.
alter table public.ledger_entries
  add column if not exists category text default 'goods',
  add column if not exists payment_method text default 'cash',
  add column if not exists reference_number text,
  add column if not exists bank_or_agent_name text,
  add column if not exists attachment_url text;  -- temporary/deprecated: phase 1 moves it to the files subsystem

alter table public.ledger_entries alter column category drop default;
alter table public.ledger_entries
  alter column category type public.ledger_entry_category
  using (case when category in ('goods','service','cash','transfer','discount','other') then category else 'other' end)::public.ledger_entry_category,
  alter column category set default 'goods'::public.ledger_entry_category;
alter table public.ledger_entries alter column category set not null;

alter table public.ledger_entries alter column payment_method drop default;
alter table public.ledger_entries
  alter column payment_method type public.ledger_payment_method
  using (case when payment_method in ('cash','bank_transfer','cheque','offset','discount','other') then payment_method else 'other' end)::public.ledger_payment_method,
  alter column payment_method set default 'cash'::public.ledger_payment_method;
alter table public.ledger_entries alter column payment_method set not null;

-- ============================================================================
-- 3. Corrected customer_currency_balances table
--    (FK to customers — not profiles; RESTRICT — not CASCADE; no dead service_role
--     policy; write path exclusively through the security-definer trigger)
-- ============================================================================
create table if not exists public.customer_currency_balances (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  business_customer_id uuid not null references public.business_customers(id) on delete restrict,
  customer_id uuid references public.customers(id) on delete restrict,
  currency_code varchar(3) not null check (currency_code ~ '^[A-Z]{3}$'),
  current_balance numeric(20,4) not null default 0.0000,
  total_debits numeric(20,4) not null default 0.0000,
  total_credits numeric(20,4) not null default 0.0000,
  entry_count bigint not null default 0,
  last_entry_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint uq_customer_currency unique(business_customer_id, currency_code)
);

create index if not exists idx_cust_curr_bal_lookup
on public.customer_currency_balances(business_id, business_customer_id, currency_code);

create index if not exists idx_cust_curr_bal_cust_id
on public.customer_currency_balances(customer_id, currency_code);

alter table public.customer_currency_balances enable row level security;
revoke all on public.customer_currency_balances from anon, authenticated;
grant select on public.customer_currency_balances to authenticated;
-- No UPDATE/DELETE/INSERT grants at all: writes happen only via the balance trigger.
-- No service_role policy: service_role bypasses RLS anyway.

create policy customer_currency_balances_select_member
on public.customer_currency_balances for select to authenticated
using (
  private.is_business_member(business_id, null)
  or (customer_id is not null and private.is_customer_owner(customer_id))
);

create trigger trg_ccb_updated_at before update on public.customer_currency_balances
for each row execute function private.set_updated_at();

-- Defensive deterrent: blocks any UPDATE/DELETE that does not come from the balance
-- trigger (which sets the 'private.balance_trigger' GUC via set_config before writing).
create or replace function private.assert_ccb_trigger_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('private.balance_trigger', true) is distinct from 'on' then
    raise exception 'Direct mutation of customer_currency_balances is not allowed' using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger trg_ccb_no_manual_mutation before update or delete on public.customer_currency_balances
for each row execute function private.assert_ccb_trigger_mutation();

-- ============================================================================
-- 4. Corrected balance trigger (debit/credit — was the broken 'in'/'out')
-- ============================================================================
create or replace function private.trig_update_customer_currency_balance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sign smallint;
  v_debit numeric(20,4) := 0;
  v_credit numeric(20,4) := 0;
begin
  if new.direction = 'debit' then
    v_sign := 1;  v_debit := new.amount;
  else  -- 'credit'
    v_sign := -1; v_credit := new.amount;
  end if;

  -- Allow the ON CONFLICT update past the defensive deterrent trigger.
  perform set_config('private.balance_trigger', 'on', true);

  insert into public.customer_currency_balances
    (business_id, business_customer_id, customer_id, currency_code,
     current_balance, total_debits, total_credits, entry_count, last_entry_at, updated_at)
  values
    (new.business_id, new.business_customer_id, new.customer_id, new.currency_code,
     new.amount * v_sign, v_debit, v_credit, 1, coalesce(new.occurred_at, now()), now())
  on conflict (business_customer_id, currency_code) do update set
    customer_id     = coalesce(excluded.customer_id, customer_currency_balances.customer_id),
    current_balance = customer_currency_balances.current_balance + excluded.current_balance,
    total_debits    = customer_currency_balances.total_debits + excluded.total_debits,
    total_credits   = customer_currency_balances.total_credits + excluded.total_credits,
    entry_count     = customer_currency_balances.entry_count + 1,
    last_entry_at   = greatest(customer_currency_balances.last_entry_at, excluded.last_entry_at),
    updated_at      = now();
  return new;
end;
$$;

create trigger trg_ledger_entry_currency_balance
after insert on public.ledger_entries
for each row execute function private.trig_update_customer_currency_balance();

-- Backfill from the authoritative ledger (derived table; safe to rebuild).
insert into public.customer_currency_balances
  (business_id, business_customer_id, customer_id, currency_code,
   current_balance, total_debits, total_credits, entry_count, last_entry_at, updated_at)
select
  le.business_id, le.business_customer_id, le.customer_id, le.currency_code,
  sum(case when le.direction = 'debit' then le.amount else -le.amount end),
  sum(case when le.direction = 'debit' then le.amount else 0 end),
  sum(case when le.direction = 'credit' then le.amount else 0 end),
  count(*), max(le.occurred_at), now()
from public.ledger_entries le
group by le.business_id, le.business_customer_id, le.customer_id, le.currency_code
on conflict (business_customer_id, currency_code) do nothing;

-- ============================================================================
-- 5. validate_ledger_entry_insert: allowlist membership instead of single-currency
--    (create or replace keeps the existing trg_validate_ledger_entry attached; with
--     additional_currencies='{}' behavior is identical to before)
-- ============================================================================
create or replace function private.validate_ledger_entry_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bc public.business_customers%rowtype;
  v_original public.ledger_entries%rowtype;
begin
  select * into v_bc from public.business_customers where id = new.business_customer_id;
  if not found or v_bc.business_id <> new.business_id or v_bc.customer_id <> new.customer_id then
    raise exception 'Ledger tenant/customer mismatch';
  end if;
  if not private.business_allows_currency(new.business_id, new.currency_code) then
    raise exception 'Currency or business status mismatch';
  end if;
  if not private.is_business_member(new.business_id, array['owner','admin','accountant','cashier']::public.business_role[]) then
    raise exception 'Not authorized to create ledger entries' using errcode = '42501';
  end if;
  if new.entry_type in ('opening_balance','discount')
     and not private.is_business_member(new.business_id, array['owner','admin','accountant']::public.business_role[]) then
    raise exception '% requires an elevated role', new.entry_type using errcode = '42501';
  end if;
  if new.entry_type = 'reversal' then
    select * into v_original from public.ledger_entries where id = new.reversal_of_entry_id for update;
    if not found or v_original.business_id <> new.business_id or v_original.customer_id <> new.customer_id then
      raise exception 'Invalid reversal target';
    end if;
    if v_original.entry_type = 'reversal' then raise exception 'A reversal cannot reverse another reversal'; end if;
    if new.amount <> v_original.amount or new.currency_code <> v_original.currency_code then
      raise exception 'Reversal must match original amount and currency';
    end if;
    if new.direction = v_original.direction then raise exception 'Reversal direction must be opposite'; end if;
  end if;
  return new;
end;
$$;

-- ============================================================================
-- 6. Currency in the double-entry layer
--    The journal-writing functions are owned by 0015 (S4/S6) and are currency-unaware;
--    the defensive fill triggers below stamp the correct currency on every insert so
--    the NOT NULL columns hold regardless of which function version writes the rows.
-- ============================================================================
alter table public.journal_entries
  add column if not exists currency_code varchar(3) check (currency_code ~ '^[A-Z]{3}$');
alter table public.journal_entry_lines
  add column if not exists currency_code varchar(3) check (currency_code ~ '^[A-Z]{3}$');

-- Historical backfill: from the source ledger entry, else the business base currency.
update public.journal_entries je
set currency_code = le.currency_code
from public.ledger_entries le
where le.id = je.source_ledger_entry_id and je.currency_code is null;
update public.journal_entries je
set currency_code = b.currency_code
from public.businesses b
where b.id = je.business_id and je.currency_code is null;
update public.journal_entry_lines jel
set currency_code = je.currency_code
from public.journal_entries je
where je.id = jel.journal_entry_id and jel.currency_code is null;

-- Defensive fill: header currency defaults to the source ledger entry's currency,
-- else the business base currency. Runs before any writer that omits the column.
create or replace function private.fill_journal_entry_currency()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.currency_code is null then
    select coalesce(
      (select le.currency_code from public.ledger_entries le where le.id = new.source_ledger_entry_id),
      (select b.currency_code from public.businesses b where b.id = new.business_id)
    ) into new.currency_code;
  end if;
  return new;
end;
$$;

create trigger trg_journal_entries_fill_currency
before insert on public.journal_entries
for each row execute function private.fill_journal_entry_currency();

-- Defensive fill + enforcement: a line without a currency inherits its header's;
-- a mismatched currency is rejected (single-currency journal invariant).
-- Fires before trg_validate_journal_entry_line (alphabetical trigger order).
create or replace function private.fill_and_assert_journal_line_currency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_currency varchar(3);
begin
  select currency_code into v_currency from public.journal_entries where id = new.journal_entry_id;
  if new.currency_code is null then
    new.currency_code := v_currency;
  end if;
  if v_currency is null or new.currency_code is distinct from v_currency then
    raise exception 'Journal line currency must match its journal entry currency' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger trg_journal_line_currency_fill
before insert or update on public.journal_entry_lines
for each row execute function private.fill_and_assert_journal_line_currency();

alter table public.journal_entries alter column currency_code set not null;
alter table public.journal_entry_lines alter column currency_code set not null;

-- ============================================================================
-- 7. Currency-grouped balance views (one row per customer × currency; never sums
--    two currencies into one number). public.customer_business_summary derives from
--    business_customer_balances and inherits the per-currency rows automatically.
--    NOTE: public.account_trial_balance is owned by 0015 (S8 rebuild) — see header.
-- ============================================================================
create or replace view public.business_customer_balances
with (security_invoker = true)
as
select
  bc.id as business_customer_id,
  bc.business_id,
  bc.customer_id,
  bc.local_display_name,
  coalesce(le.currency_code, b.currency_code) as currency_code,
  coalesce(sum(case when le.direction = 'debit' then le.amount else -le.amount end), 0)::numeric(20,4) as current_balance,
  coalesce(sum(case when le.due_date < current_date and le.direction = 'debit' and not les.is_reversed then le.amount else 0 end), 0)::numeric(20,4) as gross_overdue_debits,
  count(le.id) as entry_count,
  max(le.occurred_at) as last_entry_at
from public.business_customers bc
join public.businesses b on b.id = bc.business_id
left join public.ledger_entries le on le.business_customer_id = bc.id
left join public.ledger_entry_state les on les.entry_id = le.id
group by bc.id, bc.business_id, bc.customer_id, bc.local_display_name, coalesce(le.currency_code, b.currency_code);

create or replace view public.business_customer_account_positions
with (security_invoker = true)
as
select
  bc.id as business_customer_id, bc.business_id, bc.customer_id, bc.local_display_name,
  coalesce(le.currency_code, b.currency_code) as currency_code,
  coalesce(sum(case when le.direction = 'debit' then le.amount else -le.amount end), 0)::numeric(20,4) as receivable_signed_balance,
  greatest(coalesce(sum(case when le.direction = 'debit' then le.amount else -le.amount end), 0), 0)::numeric(20,4) as amount_customer_owes,
  greatest(-coalesce(sum(case when le.direction = 'debit' then le.amount else -le.amount end), 0), 0)::numeric(20,4) as amount_business_owes_customer
from public.business_customers bc
join public.businesses b on b.id = bc.business_id
left join public.ledger_entries le on le.business_customer_id = bc.id
group by bc.id, bc.business_id, bc.customer_id, bc.local_display_name, coalesce(le.currency_code, b.currency_code);

-- ============================================================================
-- 8. Reconciliation: derived balances must always equal the authoritative ledger
-- ============================================================================
create or replace function private.reconcile_customer_currency_balances(p_business_id uuid default null)
returns table(business_customer_id uuid, currency_code varchar, stored numeric, computed numeric, drift numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select
    le.business_customer_id,
    le.currency_code,
    coalesce(ccb.current_balance, 0) as stored,
    sum(case when le.direction = 'debit' then le.amount else -le.amount end) as computed,
    coalesce(ccb.current_balance, 0) - sum(case when le.direction = 'debit' then le.amount else -le.amount end) as drift
  from public.ledger_entries le
  left join public.customer_currency_balances ccb
    on ccb.business_customer_id = le.business_customer_id and ccb.currency_code = le.currency_code
  where (p_business_id is null or le.business_id = p_business_id)
  group by le.business_customer_id, le.currency_code, ccb.current_balance
  having coalesce(ccb.current_balance, 0) <> sum(case when le.direction = 'debit' then le.amount else -le.amount end)
$$;

-- Ready for the phase-1 scheduled reconciliation job (pgTAP runs as superuser).
grant execute on function private.reconcile_customer_currency_balances(uuid) to service_role;

commit;

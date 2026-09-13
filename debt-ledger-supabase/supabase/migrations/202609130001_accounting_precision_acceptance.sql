-- Phase 4: currency-aware decimal precision and end-to-end accounting reconciliation.
begin;

update public.currencies as c
set decimal_scale = v.decimal_scale, updated_at = now()
from (values
  ('YER',2),('SAR',2),('USD',2),('EUR',2),('AED',2),('KWD',3),
  ('QAR',2),('BHD',3),('OMR',3),('GBP',2),('JPY',0)
) as v(code,decimal_scale)
where c.code=v.code;

create or replace function private.assert_currency_amount_scale()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare v_scale smallint;
begin
  select decimal_scale into v_scale
  from public.currencies
  where code=new.currency_code and is_active;
  if v_scale is null then
    raise exception 'Currency % is not active',new.currency_code using errcode='22023';
  end if;
  if new.amount<>round(new.amount,v_scale) then
    raise exception 'Currency % supports at most % decimal places',new.currency_code,v_scale
      using errcode='22023';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ledger_currency_amount_scale on public.ledger_entries;
create trigger trg_ledger_currency_amount_scale
before insert or update of amount,currency_code on public.ledger_entries
for each row execute function private.assert_currency_amount_scale();

create or replace function private.assert_journal_line_currency_scale()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare v_scale smallint;
begin
  select decimal_scale into v_scale
  from public.currencies
  where code=new.currency_code and is_active;
  if v_scale is null
     or new.debit_amount<>round(new.debit_amount,v_scale)
     or new.credit_amount<>round(new.credit_amount,v_scale) then
    raise exception 'Journal amount does not match currency % precision',new.currency_code
      using errcode='22023';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_journal_line_currency_scale on public.journal_entry_lines;
create trigger trg_journal_line_currency_scale
before insert or update of debit_amount,credit_amount,currency_code
on public.journal_entry_lines
for each row execute function private.assert_journal_line_currency_scale();

-- One row per business/currency. No cross-currency aggregation is possible.
create or replace view public.accounting_reconciliation
with (security_invoker=true)
as
with scope as (
  select business_id,currency_code from public.ledger_entries
  union
  select je.business_id,jel.currency_code
  from public.journal_entry_lines jel
  join public.journal_entries je on je.id=jel.journal_entry_id
), ledger as (
  select business_id,currency_code,
    sum(case when direction='debit' then amount else -amount end)::numeric(20,4) balance
  from public.ledger_entries group by business_id,currency_code
), customer_projection as (
  select business_id,currency_code,sum(current_balance)::numeric(20,4) balance
  from public.business_customer_balances group by business_id,currency_code
), ar_journal as (
  select je.business_id,jel.currency_code,
    sum(jel.debit_amount-jel.credit_amount)::numeric(20,4) balance
  from public.journal_entry_lines jel
  join public.journal_entries je on je.id=jel.journal_entry_id and je.status='posted'
  join public.business_accounting_settings s
    on s.business_id=je.business_id and s.accounts_receivable_account_id=jel.account_id
  group by je.business_id,jel.currency_code
), trial as (
  select business_id,currency_code,signed_balance::numeric(20,4) balance
  from public.account_trial_balance where account_code='1100'
)
select s.business_id,s.currency_code,
  coalesce(l.balance,0)::numeric(20,4) ledger_balance,
  coalesce(cp.balance,0)::numeric(20,4) customer_balance,
  coalesce(aj.balance,0)::numeric(20,4) journal_ar_balance,
  coalesce(t.balance,0)::numeric(20,4) trial_balance,
  (coalesce(l.balance,0)=coalesce(cp.balance,0)
   and coalesce(l.balance,0)=coalesce(aj.balance,0)
   and coalesce(l.balance,0)=coalesce(t.balance,0)) as is_reconciled
from scope s
left join ledger l using(business_id,currency_code)
left join customer_projection cp using(business_id,currency_code)
left join ar_journal aj using(business_id,currency_code)
left join trial t using(business_id,currency_code);

grant select on public.accounting_reconciliation to authenticated;

commit;

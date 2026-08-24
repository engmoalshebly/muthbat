-- P1: fixed-point money boundaries, official currencies, separate bank account,
-- accurate overdue balances, and an actual scheduled AR reconciliation.
begin;

create table if not exists public.currencies (
  code varchar(3) primary key check (code ~ '^[A-Z]{3}$'),
  name text not null check (char_length(trim(name)) between 2 and 120),
  symbol text not null check (char_length(trim(symbol)) between 1 and 12),
  decimal_scale smallint not null default 4 check (decimal_scale between 0 and 4),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.currencies(code,name,symbol,decimal_scale,is_active)
values
  ('YER','ريال يمني','ر.ي',4,true),
  ('SAR','ريال سعودي','ر.س',4,true),
  ('USD','دولار أمريكي','$',4,true),
  ('EUR','يورو','€',4,true),
  ('AED','درهم إماراتي','د.إ',4,true),
  ('KWD','دينار كويتي','د.ك',4,true),
  ('QAR','ريال قطري','ر.ق',4,true),
  ('BHD','دينار بحريني','د.ب',4,true),
  ('OMR','ريال عماني','ر.ع',4,true),
  ('GBP','جنيه إسترليني','£',4,true),
  ('JPY','ين ياباني','¥',4,true)
on conflict(code) do update set name=excluded.name,symbol=excluded.symbol,
  decimal_scale=excluded.decimal_scale,is_active=excluded.is_active,updated_at=now();

alter table public.currencies enable row level security;
revoke all on public.currencies from anon,authenticated;
grant select on public.currencies to authenticated;
drop policy if exists currencies_select_active on public.currencies;
create policy currencies_select_active on public.currencies
  for select to authenticated using (is_active);

create or replace function private.business_allows_currency(p_business_id uuid,p_currency text)
returns boolean language sql stable security definer set search_path=''
as $$
  select exists(
    select 1 from public.businesses b
    join public.currencies c on c.code=upper(trim(p_currency)) and c.is_active
    where b.id=p_business_id and b.status='active'
      and (b.currency_code=c.code or c.code=any(b.additional_currencies))
  )
$$;

create or replace function private.validate_business_currency_configuration()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_code text;
begin
  if not exists(select 1 from public.currencies where code=new.currency_code and is_active) then
    raise exception 'Base currency is not active in the official currency catalog' using errcode='22023';
  end if;
  foreach v_code in array coalesce(new.additional_currencies,'{}'::text[]) loop
    if not exists(select 1 from public.currencies where code=upper(trim(v_code)) and is_active) then
      raise exception 'Additional currency % is not active in the official currency catalog',v_code using errcode='22023';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_validate_business_currency_configuration on public.businesses;
create trigger trg_validate_business_currency_configuration
before insert or update of currency_code,additional_currencies on public.businesses
for each row execute function private.validate_business_currency_configuration();

-- Explicit fixed-point checks. The column type already prevents storage beyond
-- four places; these checks make the invariant visible and fail loudly.
alter table public.ledger_entries drop constraint if exists ledger_entries_amount_scale;
alter table public.ledger_entries add constraint ledger_entries_amount_scale check (amount=round(amount,4));
alter table public.customer_currency_balances drop constraint if exists customer_currency_balances_amount_scale;
alter table public.customer_currency_balances add constraint customer_currency_balances_amount_scale
  check (current_balance=round(current_balance,4) and total_debits=round(total_debits,4) and total_credits=round(total_credits,4));

-- Separate cash and bank control accounts.
alter table public.business_accounting_settings add column if not exists bank_account_id uuid;
alter table public.business_accounting_settings drop constraint if exists business_accounting_settings_bank_account_fk;
alter table public.business_accounting_settings add constraint business_accounting_settings_bank_account_fk
  foreign key(bank_account_id) references public.chart_of_accounts(id) on delete restrict;
alter table public.business_accounting_settings drop constraint if exists business_accounting_settings_cash_bank_distinct;
alter table public.business_accounting_settings add constraint business_accounting_settings_cash_bank_distinct
  check (bank_account_id is null or bank_account_id<>cash_account_id);

create or replace function private.initialize_business_chart(p_business_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_ar uuid; v_cash uuid; v_bank uuid; v_sales uuid; v_discount uuid; v_opening uuid;
begin
  insert into public.chart_of_accounts(business_id,account_code,account_name,account_class,normal_balance,is_control_account,allows_manual_posting)
  values
    (p_business_id,'1000','Cash on hand','asset','debit',false,true),
    (p_business_id,'1010','Bank account','asset','debit',false,true),
    (p_business_id,'1100','Accounts receivable','asset','debit',true,false),
    (p_business_id,'3100','Opening balance equity','equity','credit',false,false),
    (p_business_id,'4000','Sales revenue','revenue','credit',false,true),
    (p_business_id,'5100','Sales discounts','expense','debit',false,true)
  on conflict(business_id,account_code) do nothing;
  select id into v_cash from public.chart_of_accounts where business_id=p_business_id and account_code='1000';
  select id into v_bank from public.chart_of_accounts where business_id=p_business_id and account_code='1010';
  select id into v_ar from public.chart_of_accounts where business_id=p_business_id and account_code='1100';
  select id into v_opening from public.chart_of_accounts where business_id=p_business_id and account_code='3100';
  select id into v_sales from public.chart_of_accounts where business_id=p_business_id and account_code='4000';
  select id into v_discount from public.chart_of_accounts where business_id=p_business_id and account_code='5100';
  insert into public.business_accounting_settings(
    business_id,accounts_receivable_account_id,cash_account_id,bank_account_id,
    sales_revenue_account_id,sales_discount_account_id,opening_balance_equity_account_id
  ) values(p_business_id,v_ar,v_cash,v_bank,v_sales,v_discount,v_opening)
  on conflict(business_id) do update set bank_account_id=coalesce(business_accounting_settings.bank_account_id,excluded.bank_account_id);
end;
$$;

do $$
declare v_business record;
begin
  for v_business in select id from public.businesses loop
    perform private.initialize_business_chart(v_business.id);
  end loop;
end $$;

update public.business_accounting_settings s
set bank_account_id=coa.id
from public.chart_of_accounts coa
where s.bank_account_id is null and coa.business_id=s.business_id and coa.account_code='1010';
alter table public.business_accounting_settings alter column bank_account_id set not null;

create or replace function private.post_ledger_entry_journal(p_ledger_entry_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_entry public.ledger_entries%rowtype; v_journal uuid; v_original_journal uuid;
  v_settings public.business_accounting_settings%rowtype; v_line_no smallint:=0; v_cash_account uuid;
begin
  select * into v_entry from public.ledger_entries where id=p_ledger_entry_id;
  if not found then raise exception 'Ledger entry not found'; end if;
  select id into v_journal from public.journal_entries where source_ledger_entry_id=p_ledger_entry_id;
  if v_journal is not null then return v_journal; end if;
  perform private.assert_posting_period_open(v_entry.business_id,(v_entry.occurred_at at time zone (select timezone from public.businesses where id=v_entry.business_id))::date);
  select * into v_settings from public.business_accounting_settings where business_id=v_entry.business_id;
  if not found then raise exception 'Business accounting settings are not initialized'; end if;
  v_cash_account:=case when v_entry.payment_method in ('bank_transfer','cheque') then v_settings.bank_account_id else v_settings.cash_account_id end;
  insert into public.journal_entries(business_id,source_ledger_entry_id,source_type,source_reference,entry_date,description,posted_by_user_id)
  values(v_entry.business_id,v_entry.id,'ledger_entry',v_entry.external_reference,
    (v_entry.occurred_at at time zone (select timezone from public.businesses where id=v_entry.business_id))::date,
    left('Ledger entry '||v_entry.entry_type::text||': '||v_entry.description,500),v_entry.created_by_user_id)
  returning id into v_journal;
  if v_entry.entry_type='reversal' then
    select id into v_original_journal from public.journal_entries where source_ledger_entry_id=v_entry.reversal_of_entry_id;
    if v_original_journal is null then perform private.post_ledger_entry_journal(v_entry.reversal_of_entry_id); select id into v_original_journal from public.journal_entries where source_ledger_entry_id=v_entry.reversal_of_entry_id; end if;
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount,credit_amount)
    select v_journal,row_number() over(order by line_number)::smallint,account_id,business_customer_id,'Reversal of ledger entry '||v_entry.reversal_of_entry_id::text,credit_amount,debit_amount
    from public.journal_entry_lines where journal_entry_id=v_original_journal order by line_number;
    return v_journal;
  end if;
  if v_entry.entry_type in ('opening_balance','debt') then
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount)
    values(v_journal,1,v_settings.accounts_receivable_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,credit_amount)
    values(v_journal,2,case when v_entry.entry_type='opening_balance' then v_settings.opening_balance_equity_account_id else v_settings.sales_revenue_account_id end,v_entry.business_customer_id,v_entry.description,v_entry.amount);
  elsif v_entry.entry_type='payment' then
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount)
    values(v_journal,1,v_cash_account,v_entry.business_customer_id,v_entry.description,v_entry.amount);
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,credit_amount)
    values(v_journal,2,v_settings.accounts_receivable_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
  elsif v_entry.entry_type='discount' then
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount)
    values(v_journal,1,v_settings.sales_discount_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,credit_amount)
    values(v_journal,2,v_settings.accounts_receivable_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
  else raise exception 'Unsupported ledger entry type %',v_entry.entry_type;
  end if;
  return v_journal;
end;
$$;

-- Discount RPC gets the same four-decimal and official-currency contract as debt/payment.
create or replace function private.command_apply_customer_discount(
  p_business_customer_id uuid,p_amount numeric,p_description text,p_occurred_at timestamptz default now(),
  p_client_request_id uuid default gen_random_uuid(),p_currency_code varchar default null
)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_currency varchar(3); v_balance numeric(20,4); v_id uuid; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,4) then raise exception 'Discount amount must be positive and support at most 4 decimal places' using errcode='22023'; end if;
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then raise exception 'Business customer not found or archived'; end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  select id into v_id from public.ledger_entries where business_id=v_bc.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
  if v_currency is null then raise exception 'Business is not active'; end if;
  if p_currency_code is not null then v_currency:=upper(trim(p_currency_code)); end if;
  if not private.business_allows_currency(v_bc.business_id,v_currency) then raise exception 'Currency not allowed for this business' using errcode='22023'; end if;
  select coalesce(sum(case when direction='debit' then amount else -amount end),0) into v_balance from public.ledger_entries where business_customer_id=p_business_customer_id and currency_code=v_currency;
  if v_balance<=0 or p_amount>v_balance then raise exception 'Discount cannot exceed the outstanding debit balance'; end if;
  insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,category,payment_method,description,occurred_at,client_request_id,created_by_user_id)
  values(v_bc.business_id,v_bc.id,v_bc.customer_id,'discount','credit',p_amount,v_currency,'discount','discount',trim(p_description),coalesce(p_occurred_at,now()),v_request_id,(select auth.uid())) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'apply_customer_discount','accepted',v_id,jsonb_build_object('entry_id',v_id,'currency_code',v_currency)) on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

-- Accurate overdue debt: payments/discounts are allocated FIFO to actual debt
-- principals, and reversed entries are excluded from the allocation.
drop view if exists public.customer_business_summary;
drop view if exists public.business_customer_balances;
create view public.business_customer_balances with (security_invoker=true) as
with active_entries as (
  select le.* from public.ledger_entries le
  left join public.ledger_entry_state les on les.entry_id=le.id
  where not coalesce(les.is_reversed,false)
), balances as (
  select business_customer_id,currency_code,
    coalesce(sum(case when direction='debit' then amount else -amount end),0)::numeric(20,4) current_balance,
    count(*) entry_count,max(occurred_at) last_entry_at
  from active_entries group by business_customer_id,currency_code
), credits as (
  select business_customer_id,currency_code,
    coalesce(sum(case when direction='credit' then amount when entry_type='reversal' and direction='debit' then -amount else 0 end),0)::numeric(20,4) available_credits
  from active_entries group by business_customer_id,currency_code
), debt_sequence as (
  select e.*,coalesce(sum(e.amount) over(partition by e.business_customer_id,e.currency_code order by e.occurred_at,e.id rows between unbounded preceding and 1 preceding),0) debit_before
  from active_entries e
  where e.direction='debit' and e.entry_type in ('debt','opening_balance')
), overdue_debts as (
  select d.business_customer_id,d.currency_code,
    greatest(d.amount-greatest(coalesce(cr.available_credits,0)-d.debit_before,0),0) unpaid_amount
  from debt_sequence d left join credits cr on cr.business_customer_id=d.business_customer_id and cr.currency_code=d.currency_code
  where d.due_date<current_date
), overdue as (
  select business_customer_id,currency_code,coalesce(sum(unpaid_amount),0)::numeric(20,4) gross_overdue_debits
  from overdue_debts group by business_customer_id,currency_code
), scope as (
  select bc.id business_customer_id,bc.business_id,bc.customer_id,bc.local_display_name,b.currency_code
  from public.business_customers bc join public.businesses b on b.id=bc.business_id
  union
  select business_customer_id,le.business_id,le.customer_id,bc.local_display_name,le.currency_code
  from active_entries le join public.business_customers bc on bc.id=le.business_customer_id
)
select s.business_customer_id,s.business_id,s.customer_id,s.local_display_name,s.currency_code,
  coalesce(b.current_balance,0)::numeric(20,4) current_balance,
  coalesce(o.gross_overdue_debits,0)::numeric(20,4) gross_overdue_debits,
  coalesce(b.entry_count,0) entry_count,b.last_entry_at
from scope s left join balances b using(business_customer_id,currency_code) left join overdue o using(business_customer_id,currency_code);

create view public.customer_business_summary with (security_invoker=true) as
select bcb.business_customer_id,bcb.business_id,b.name as business_name,b.business_type,b.logo_path,
  bcb.customer_id,bcb.currency_code,bcb.current_balance,bcb.entry_count,bcb.last_entry_at
from public.business_customer_balances bcb join public.businesses b on b.id=bcb.business_id;

-- Schedule is idempotent by job name and runs hourly in Supabase/Postgres.
do $$
declare v_job_id bigint;
begin
  select jobid into v_job_id from cron.job where jobname='muthbat-ar-reconciliation-hourly';
  if v_job_id is not null then perform cron.unschedule(v_job_id); end if;
  perform cron.schedule('muthbat-ar-reconciliation-hourly','0 * * * *','select private.run_ar_reconciliation();');
end $$;

grant select on public.currencies to authenticated;
grant select on public.business_customer_balances,public.customer_business_summary to authenticated;
grant execute on function public.apply_customer_discount(uuid,numeric,text,timestamptz,uuid,varchar) to authenticated;

commit;

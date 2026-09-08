-- A reversal is a real immutable counter-entry.  The previous balance view
-- excluded the original entry after marking it reversed, but still counted its
-- reversal.  That double-applied the correction and could show a false credit
-- balance after a partially accepted dispute.
begin;

drop view if exists public.customer_business_summary;
drop view if exists public.business_customer_balances;

create view public.business_customer_balances with (security_invoker=true) as
with all_entries as (
  select * from public.ledger_entries
), active_entries as (
  -- Used only for overdue allocation. A reversed debt and its technical
  -- reversal must not be considered a collectible invoice or a customer credit.
  select le.*
  from public.ledger_entries le
  left join public.ledger_entry_state les on les.entry_id=le.id
  where not coalesce(les.is_reversed,false)
    and le.entry_type <> 'reversal'
), balances as (
  -- Operational balance must retain both sides of every reversal pair.
  select business_customer_id,currency_code,
    coalesce(sum(case when direction='debit' then amount else -amount end),0)::numeric(20,4) current_balance,
    count(*) entry_count,max(occurred_at) last_entry_at
  from all_entries group by business_customer_id,currency_code
), credits as (
  select business_customer_id,currency_code,
    coalesce(sum(case when direction='credit' then amount else 0 end),0)::numeric(20,4) available_credits
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
  from all_entries le join public.business_customers bc on bc.id=le.business_customer_id
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

grant select on public.business_customer_balances,public.customer_business_summary to authenticated;

commit;

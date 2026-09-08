-- 004_multi_currency.sql
-- Multi-currency pgTAP suite (fix-plan/01-migration-012.md section 6.1, phase zero).
-- Targets the contract of migration 202608190013_multi_currency_redo.sql:
--   * businesses.additional_currencies allow-list (default '{}' = single-currency behavior)
--   * corrected customer_currency_balances trigger (direction 'debit'/'credit', FK to customers)
--   * extended public.create_ledger_entry / apply_customer_discount with p_currency_code
--   * per-currency balance / credit-limit checks, journal currency, per-currency views,
--     currency-filtered statements, and private.reconcile_customer_currency_balances()
-- NOTE: this file is intentionally RED until migration 0013 lands (contract-first tests).
-- Named-argument calls are used so the file stays valid across the signature change.
-- Identity simulation follows the proven pattern from 002_core_workflow.sql.

begin;
select plan(40);

insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
  ('00000000-0000-0000-0000-000000000000','a4111111-1111-1111-1111-111111111111','authenticated','authenticated','mc-merchant@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"MC Merchant"}'::jsonb,now(),now()),
  ('00000000-0000-0000-0000-000000000000','a4222222-2222-2222-2222-222222222222','authenticated','authenticated','mc-customer@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"MC Customer"}'::jsonb,now(),now()),
  ('00000000-0000-0000-0000-000000000000','b4111111-1111-1111-1111-111111111111','authenticated','authenticated','mc-stranger@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"MC Stranger"}'::jsonb,now(),now());

-- Resolved before assuming the API role, exactly like 002_core_workflow.sql.
select set_config('test.customer_id',(select id::text from public.customers where user_id='a4222222-2222-2222-2222-222222222222'),true);

set local role authenticated;

-- Merchant builds an active store with a linked customer.
select set_config('request.jwt.claim.sub','a4111111-1111-1111-1111-111111111111',true);
select set_config('test.biz',public.create_business('Multi Currency Store','retail','YER')::text,true);
select set_config('test.bc',public.add_business_customer(current_setting('test.biz')::uuid,current_setting('test.customer_id')::uuid,'MC Customer',null)::text,true);
select set_config('test.link',public.request_customer_link(current_setting('test.bc')::uuid)::text,true);
select set_config('request.jwt.claim.sub','a4222222-2222-2222-2222-222222222222',true);
select public.respond_link_request(current_setting('test.link')::uuid,true);
select set_config('request.jwt.claim.sub','a4111111-1111-1111-1111-111111111111',true);

-- ---------- Schema contract of migration 0013 ----------
select has_table('public','customer_currency_balances','MC-01: per-currency balance table exists');
select has_column('public','businesses','additional_currencies','MC-01b: per-store currency allow-list exists');
select has_column('public','ledger_entries','category','MC-02: ledger entries carry a category');
select has_column('public','ledger_entries','payment_method','MC-02b: ledger entries carry a payment method');
select has_column('public','ledger_entries','reference_number','MC-02c: ledger entries carry a reference number');
select ok(exists(
  select 1
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  join pg_attribute a on a.attrelid = t.oid and a.attnum = any(c.conkey)
  join pg_class ft on ft.oid = c.confrelid
  join pg_namespace fn on fn.oid = ft.relnamespace
  where c.contype = 'f'
    and n.nspname = 'public' and t.relname = 'customer_currency_balances'
    and a.attname = 'customer_id'
    and fn.nspname = 'public' and ft.relname = 'customers'
),'MC-01c: customer_currency_balances.customer_id references public.customers (0012 FK bug fixed)');

-- ---------- Balance trigger in the store currency (debit/credit semantics) ----------
select set_config('test.debt_id',public.create_ledger_entry(
  p_business_customer_id := current_setting('test.bc')::uuid,
  p_entry_type := 'debt', p_amount := 100, p_description := 'MC debt 100',
  p_client_request_id := 'a4444444-4444-4444-4444-444444444444'::uuid)::text,true);
select is(
  (select entry_type::text from public.ledger_entries where id=current_setting('test.debt_id')::uuid),
  'debt', 'MC-03: debt in the store currency succeeds');

select set_config('test.payment_id',public.create_ledger_entry(
  p_business_customer_id := current_setting('test.bc')::uuid,
  p_entry_type := 'payment', p_amount := 30, p_description := 'MC payment 30',
  p_client_request_id := 'a4555555-5555-5555-5555-555555555555'::uuid)::text,true);
select is(
  (select direction::text from public.ledger_entries where id=current_setting('test.payment_id')::uuid),
  'credit', 'MC-04: payment in the store currency succeeds');

select is(
  public.create_ledger_entry(
    p_business_customer_id := current_setting('test.bc')::uuid,
    p_entry_type := 'payment', p_amount := 30, p_description := 'MC payment 30',
    p_client_request_id := 'a4555555-5555-5555-5555-555555555555'::uuid),
  current_setting('test.payment_id')::uuid,
  'MC-07: a repeated client_request_id returns the original entry (idempotency)');
select is(
  (select count(*)::integer from public.ledger_entries where business_customer_id=current_setting('test.bc')::uuid),
  2, 'MC-07b: the retried payment did not create a second entry');
select is(
  (select current_balance from public.customer_currency_balances where business_customer_id=current_setting('test.bc')::uuid and currency_code='YER'),
  70.0000::numeric, 'MC-03b: balance trigger applies debit/credit signs correctly (100 - 30)');
select is(
  (select entry_count::integer from public.customer_currency_balances where business_customer_id=current_setting('test.bc')::uuid and currency_code='YER'),
  2, 'MC-03c: balance trigger counts entries exactly once');

-- ---------- Currency allow-list enforcement ----------
select throws_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''debt'', p_amount := 10, p_currency_code := ''SAR'', p_description := ''SAR before enable'', p_client_request_id := ''a4777777-7777-7777-7777-777777777777''::uuid)',
  current_setting('test.bc')),
  null, null, 'MC-05: a currency outside the allow-list is rejected (no silent YER fallback)');

-- Enable SAR for this store (privileged data change, done as the migration role).
reset role;
update public.businesses set additional_currencies='{SAR}' where id=current_setting('test.biz')::uuid;
set local role authenticated;

select set_config('test.sar_debt_id',public.create_ledger_entry(
  p_business_customer_id := current_setting('test.bc')::uuid,
  p_entry_type := 'debt', p_amount := 50, p_currency_code := 'SAR', p_description := 'MC SAR debt 50',
  p_client_request_id := 'a4666666-6666-6666-6666-666666666666'::uuid)::text,true);
select is(
  (select currency_code from public.ledger_entries where id=current_setting('test.sar_debt_id')::uuid),
  'SAR', 'MC-06: an allow-listed currency is accepted');
select is(
  (select count(*)::integer from public.customer_currency_balances where business_customer_id=current_setting('test.bc')::uuid),
  2, 'MC-06b: a second balance row is created per currency (strict separation)');
select is(
  (select current_balance from public.customer_currency_balances where business_customer_id=current_setting('test.bc')::uuid and currency_code='SAR'),
  50.0000::numeric, 'MC-06c: the SAR balance tracks SAR entries only');

select set_config('test.sar_payment_id',public.create_ledger_entry(
  p_business_customer_id := current_setting('test.bc')::uuid,
  p_entry_type := 'payment', p_amount := 30, p_currency_code := 'SAR', p_description := 'MC SAR payment 30',
  p_client_request_id := 'a4666666-6666-4666-8666-666666666666'::uuid)::text,true);
select is(
  (select current_balance from public.customer_currency_balances where business_customer_id=current_setting('test.bc')::uuid and currency_code='SAR'),
  20.0000::numeric, 'MC-06d: SAR payment reduces only the SAR balance');

select set_config('test.sar_payment_reversal_id',public.reverse_ledger_entry(
  current_setting('test.sar_payment_id')::uuid,'MC reverse SAR payment','a4666666-6666-4666-8666-666666666667'::uuid)::text,true);
select is(
  (select currency_code from public.ledger_entries where id=current_setting('test.sar_payment_reversal_id')::uuid),
  'SAR', 'MC-06e: SAR payment reversal preserves SAR');

select throws_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''debt'', p_amount := 10, p_currency_code := ''$$$'', p_description := ''Invalid currency probe'', p_client_request_id := ''a4888888-8888-4888-8888-888888888888''::uuid)',
  current_setting('test.bc')),
  null, null, 'MC-08: a malformed currency code is rejected explicitly');

-- ---------- Per-currency balance and credit-limit checks ----------
reset role;
update public.business_accounting_settings set allow_customer_credit_balance=false where business_id=current_setting('test.biz')::uuid;
set local role authenticated;

select throws_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''payment'', p_amount := 60, p_currency_code := ''SAR'', p_description := ''SAR overpayment probe'', p_client_request_id := ''a4999999-9999-4999-9999-999999999999''::uuid)',
  current_setting('test.bc')),
  null, null, 'MC-09: a positive YER balance does not allow a SAR payment above the SAR balance');
select throws_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''payment'', p_amount := 80, p_description := ''YER overpayment probe'', p_client_request_id := ''a4aaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa''::uuid)',
  current_setting('test.bc')),
  null, null, 'MC-09b: a YER payment above the YER balance is rejected when the credit switch is off');
select lives_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''payment'', p_amount := 70, p_description := ''YER full settlement'', p_client_request_id := ''a4bbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb''::uuid)',
  current_setting('test.bc')),
  'MC-09c: a payment equal to the same-currency balance is allowed');

update public.business_customers set credit_limit=60 where id=current_setting('test.bc')::uuid;
select throws_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''debt'', p_amount := 70, p_description := ''YER limit probe'', p_client_request_id := ''a4cccccc-cccc-4ccc-cccc-cccccccccccc''::uuid)',
  current_setting('test.bc')),
  null, null, 'MC-10: the credit limit is enforced against the same-currency balance');
select lives_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''debt'', p_amount := 10, p_currency_code := ''SAR'', p_description := ''SAR within limit'', p_client_request_id := ''a4dddddd-dddd-4ddd-dddd-dddddddddddd''::uuid)',
  current_setting('test.bc')),
  'MC-10b: the SAR balance is evaluated against the limit independently (50 + 10 <= 60)');

-- A partial dispute correction must retain the disputed entry currency.
select set_config('test.sar_disputed_payment_id',public.create_ledger_entry(
  p_business_customer_id := current_setting('test.bc')::uuid,
  p_entry_type := 'payment', p_amount := 20, p_currency_code := 'SAR', p_description := 'MC disputed SAR payment',
  p_client_request_id := 'a4d11111-1111-4111-8111-111111111111'::uuid)::text,true);
select set_config('request.jwt.claim.sub','a4222222-2222-2222-2222-222222222222',true);
select set_config('test.dispute_id',public.open_dispute(
  current_setting('test.sar_disputed_payment_id')::uuid,'wrong_amount','SAR dispute','a4d22222-2222-4222-8222-222222222222'::uuid)::text,true);
select set_config('request.jwt.claim.sub','a4111111-1111-1111-1111-111111111111',true);
select set_config('test.corrected_sar_id',public.resolve_dispute(
  current_setting('test.dispute_id')::uuid,'partially_accepted','Correct SAR amount',5,'a4d33333-3333-4333-8333-333333333333'::uuid)::text,true);
select is(
  (select currency_code from public.ledger_entries where id=current_setting('test.corrected_sar_id')::uuid),
  'SAR', 'MC-10c: partial dispute correction preserves SAR');

-- ---------- Journal currency layer ----------
select ok(exists(
  select 1 from public.journal_entries
  where business_id=current_setting('test.biz')::uuid and currency_code='SAR'
),'MC-11: SAR ledger entries produce SAR-denominated journal entries');
select is(
  (select count(*)::integer from public.account_trial_balance where business_id=current_setting('test.biz')::uuid and account_code='1100'),
  2, 'MC-11b: the trial balance is grouped per currency (no cross-currency summation)');

-- A balanced manual journal whose lines disagree with the header currency must be
-- rejected by the currency-match trigger (the lines are balanced on purpose so only
-- the currency guard can fail this probe). Runs as the migration role because
-- journal tables are not writable by authenticated.
reset role;
select throws_ok(format($probe$
do $$
declare
  v_j uuid;
  v_cash uuid;
  v_rev uuid;
begin
  select id into v_cash from public.chart_of_accounts where business_id=%L::uuid and account_code='1000';
  select id into v_rev from public.chart_of_accounts where business_id=%L::uuid and account_code='4000';
  insert into public.journal_entries(business_id,source_type,entry_date,description,posted_by_user_id,currency_code)
  values (%L::uuid,'manual_adjustment',current_date,'Mixed currency probe','a4111111-1111-1111-1111-111111111111'::uuid,'YER')
  returning id into v_j;
  insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,debit_amount,credit_amount,currency_code)
  values (v_j,1,v_cash,5,0,'SAR'),(v_j,2,v_rev,0,5,'SAR');
end
$$;
$probe$,current_setting('test.biz'),current_setting('test.biz'),current_setting('test.biz')),
  null, null, 'MC-12: journal lines in a currency different from the journal header are rejected');
set local role authenticated;

-- ---------- Per-currency views and statements ----------
select is(
  (select count(*)::integer from public.business_customer_balances where business_customer_id=current_setting('test.bc')::uuid),
  2, 'MC-13: business_customer_balances returns one row per currency');
select is(
  (select count(*)::integer from public.business_customer_account_positions where business_customer_id=current_setting('test.bc')::uuid),
  2, 'MC-13b: business_customer_account_positions returns one row per currency');

select set_config('test.stmt',public.create_statement('business_customer',current_setting('test.bc')::uuid,now()-interval '1 day',now()+interval '1 day')::text,true);
select is(
  (select total_debits from public.statements where id=current_setting('test.stmt')::uuid),
  100.0000::numeric, 'MC-14: the statement aggregates the store currency only (YER debits = 100, SAR excluded)');
select is(
  (select count(*)::integer from public.statement_items where statement_id=current_setting('test.stmt')::uuid),
  3, 'MC-14b: statement items contain only the YER entries');
select set_config('test.sar_stmt',public.create_statement('business_customer',current_setting('test.bc')::uuid,now()-interval '1 day',now()+interval '1 day',null,'SAR')::text,true);
select is(
  (select currency_code from public.statements where id=current_setting('test.sar_stmt')::uuid),
  'SAR', 'MC-14c: an explicit SAR statement remains SAR and cannot mix with YER');

-- ---------- Reconciliation ----------
reset role;
select is(
  (select count(*)::integer from private.reconcile_customer_currency_balances()),
  0, 'MC-15: reconciliation between ledger_entries and currency balances reports zero drift');
set local role authenticated;

-- ---------- RLS on the derived balance table ----------
select set_config('request.jwt.claim.sub','b4111111-1111-1111-1111-111111111111',true);
select public.create_business('Stranger Store','retail','YER');
select is(
  (select count(*)::integer from public.customer_currency_balances where business_id=current_setting('test.biz')::uuid),
  0, 'MC-16: a member of another store cannot read this store currency balances');

select set_config('request.jwt.claim.sub','a4222222-2222-2222-2222-222222222222',true);
select is(
  (select count(*)::integer from public.customer_currency_balances where business_customer_id=current_setting('test.bc')::uuid),
  2, 'sanity: the linked customer reads their own per-currency balances (RLS not over-blocking)');

select set_config('request.jwt.claim.sub','a4111111-1111-1111-1111-111111111111',true);
select throws_ok(format(
  'update public.customer_currency_balances set current_balance=999 where business_customer_id=%L::uuid',
  current_setting('test.bc')),
  '42501', null, 'MC-17: direct UPDATE on currency balances is not granted to authenticated');

-- ---------- Category/payment-method enum discipline ----------
select throws_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''debt'', p_amount := 5, p_category := ''Goods'', p_description := ''Bad category probe'', p_client_request_id := ''a4eeeeee-eeee-4eee-eeee-eeeeeeeeeeee''::uuid)',
  current_setting('test.bc')),
  '22023', null, 'MC-18: a category outside the enum (case-sensitive) is rejected');
select lives_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''debt'', p_amount := 5, p_category := ''service'', p_description := ''Service debt'', p_client_request_id := ''a4ffffff-ffff-4fff-ffff-ffffffffffff''::uuid)',
  current_setting('test.bc')),
  'MC-18b: a valid category enum value is accepted');

reset role;
select is(
  (select count(*)::integer from private.reconcile_customer_currency_balances()),
  0, 'MC-15b: reconciliation still reports zero drift after every scenario above');

select * from finish();
rollback;

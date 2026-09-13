begin;
select plan(14);

insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
  ('00000000-0000-0000-0000-000000000000','a4111111-1111-4111-8111-111111111111','authenticated','authenticated','phase4-merchant@example.test','not-used',now(),'{}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','a4222222-2222-4222-8222-222222222222','authenticated','authenticated','phase4-customer@example.test','not-used',now(),'{}','{}',now(),now());

select set_config('test.customer_id',(select id::text from public.customers where user_id='a4222222-2222-4222-8222-222222222222'),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','a4111111-1111-4111-8111-111111111111',true);
select set_config('test.business_id',public.create_business('Phase 4 Store','retail','USD')::text,true);
select set_config('test.bc_id',public.add_business_customer(current_setting('test.business_id')::uuid,current_setting('test.customer_id')::uuid,'Phase 4 Customer',null)::text,true);

select is((select decimal_scale from public.currencies where code='JPY'),0::smallint,'JPY has zero minor decimals');
select is((select decimal_scale from public.currencies where code='USD'),2::smallint,'USD has two minor decimals');
select is((select decimal_scale from public.currencies where code='KWD'),3::smallint,'KWD has three minor decimals');
select throws_ok(
  format('select public.create_ledger_entry(p_business_customer_id:=''%s'',p_entry_type:=''debt'',p_amount:=1.001,p_description:=''invalid cents'',p_currency_code:=''USD'')',current_setting('test.bc_id')),
  '22023',null,'currency-specific excessive precision is rejected'
);

select set_config('test.opening',public.create_ledger_entry(current_setting('test.bc_id')::uuid,'opening_balance',100.25,'Opening',p_client_request_id:=gen_random_uuid(),p_currency_code:='USD')::text,true);
select set_config('test.debt',public.create_ledger_entry(current_setting('test.bc_id')::uuid,'debt',50.10,'Debt',p_occurred_at:='2026-09-13 10:00:00+00',p_client_request_id:=gen_random_uuid(),p_currency_code:='USD')::text,true);
select set_config('test.payment',public.create_ledger_entry(current_setting('test.bc_id')::uuid,'payment',20.05,'Payment',p_occurred_at:='2026-09-13 10:00:00+00',p_client_request_id:=gen_random_uuid(),p_currency_code:='USD')::text,true);
select set_config('test.discount',public.apply_customer_discount(current_setting('test.bc_id')::uuid,5.05,'Discount',now(),gen_random_uuid(),'USD')::text,true);

select is((select current_balance from public.business_customer_balances where business_customer_id=current_setting('test.bc_id')::uuid and currency_code='USD'),125.25::numeric,'opening, debt, payment and discount balance exactly');
select is((select count(*)::int from public.ledger_entries where business_customer_id=current_setting('test.bc_id')::uuid and occurred_at='2026-09-13 10:00:00+00'),2,'same-timestamp operations are both retained');

select set_config('test.reversal',public.reverse_ledger_entry(current_setting('test.payment')::uuid,'Reverse payment',gen_random_uuid())::text,true);
select is((select current_balance from public.business_customer_balances where business_customer_id=current_setting('test.bc_id')::uuid and currency_code='USD'),145.30::numeric,'payment reversal restores the exact amount');
select throws_ok(
  format('select public.reverse_ledger_entry(''%s''::uuid,''again'',gen_random_uuid())',current_setting('test.payment')),
  'P0001',null,'duplicate reversal is rejected'
);

select public.reverse_ledger_entry(current_setting('test.opening')::uuid,'Reverse opening',gen_random_uuid());
select public.reverse_ledger_entry(current_setting('test.debt')::uuid,'Reverse debt',gen_random_uuid());
select public.reverse_ledger_entry(current_setting('test.discount')::uuid,'Reverse discount',gen_random_uuid());
select is((select count(*)::int from public.ledger_entries where business_customer_id=current_setting('test.bc_id')::uuid and entry_type='reversal'),4,'every financial entry type can be reversed');
select is((select current_balance from public.business_customer_balances where business_customer_id=current_setting('test.bc_id')::uuid and currency_code='USD'),0.0000::numeric,'reversing every type restores the exact opening state');

-- A thousand deterministic operations exercise exact NUMERIC arithmetic and journals.
do $$
declare i integer;
begin
  for i in 1..1000 loop
    perform public.create_ledger_entry(
      current_setting('test.bc_id')::uuid,
      case when i%2=0 then 'debt'::public.ledger_entry_type else 'payment'::public.ledger_entry_type end,
      ((i%97)+1)::numeric/100,
      'randomized acceptance '||i,
      p_occurred_at:='2026-09-13 11:00:00+00',
      p_client_request_id:=gen_random_uuid(),
      p_currency_code:='USD'
    );
  end loop;
end $$;

select ok(not exists(select 1 from public.accounting_reconciliation where business_id=current_setting('test.business_id')::uuid and not is_reconciled),'customer, ledger, journal AR and trial balance reconcile');
select ok(not exists(
  select 1 from public.journal_entries je left join public.ledger_entries le on le.id=je.source_ledger_entry_id
  where je.business_id=current_setting('test.business_id')::uuid and je.source_type='ledger_entry' and le.id is null
),'there are no orphan ledger journals');
select ok(not exists(
  select 1 from public.journal_entries je join public.journal_entry_lines jl on jl.journal_entry_id=je.id
  where je.business_id=current_setting('test.business_id')::uuid group by je.id having sum(jl.debit_amount)<>sum(jl.credit_amount)
),'every journal remains double-entry balanced');
select is((select count(*)::int from public.accounting_reconciliation where business_id=current_setting('test.business_id')::uuid),1,'currencies are reconciled separately, never aggregated');

select * from finish();
rollback;

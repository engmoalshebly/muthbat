begin;
select plan(10);

insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
  ('00000000-0000-0000-0000-000000000000','91111111-1111-1111-1111-111111111111','authenticated','authenticated','accounting-merchant@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"Accounting Merchant"}'::jsonb,now(),now()),
  ('00000000-0000-0000-0000-000000000000','92222222-2222-2222-2222-222222222222','authenticated','authenticated','accounting-customer@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"Accounting Customer"}'::jsonb,now(),now());

select set_config('test.customer_id',(select id::text from public.customers where user_id='92222222-2222-2222-2222-222222222222'),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','91111111-1111-1111-1111-111111111111',true);
select set_config('test.business_id',public.create_business('Accounting Store','retail','YER')::text,true);

select is(
  (select count(*)::integer from public.chart_of_accounts where business_id=current_setting('test.business_id')::uuid),
  6, 'Creating a business initializes its six required system accounts'
);
select is(
  (select account_code from public.chart_of_accounts where business_id=current_setting('test.business_id')::uuid and is_control_account),
  '1100', 'Accounts receivable is installed as the protected control account'
);

select set_config('test.business_customer_id',public.add_business_customer(current_setting('test.business_id')::uuid,current_setting('test.customer_id')::uuid,'Accounting Customer',1000)::text,true);
select set_config('test.link_request_id',public.request_customer_link(current_setting('test.business_customer_id')::uuid)::text,true);
select set_config('request.jwt.claim.sub','92222222-2222-2222-2222-222222222222',true);
select public.respond_link_request(current_setting('test.link_request_id')::uuid,true);

select set_config('request.jwt.claim.sub','91111111-1111-1111-1111-111111111111',true);
select set_config('test.debt_id',public.create_ledger_entry(p_business_customer_id := current_setting('test.business_customer_id')::uuid,p_entry_type := 'debt',p_amount := 200,p_description := 'Accounting invoice',p_occurred_at := now(),p_client_request_id := '94444444-4444-4444-4444-444444444444'::uuid)::text,true);
select set_config('test.discount_id',public.apply_customer_discount(current_setting('test.business_customer_id')::uuid,20,'Approved settlement discount',now(),'95555555-5555-5555-5555-555555555555')::text,true);
select set_config('test.payment_id',public.create_ledger_entry(p_business_customer_id := current_setting('test.business_customer_id')::uuid,p_entry_type := 'payment',p_amount := 230,p_description := 'Advance-inclusive payment',p_occurred_at := now(),p_client_request_id := '96666666-6666-6666-6666-666666666666'::uuid)::text,true);

select is(
  (select count(*)::integer from public.journal_entries where business_id=current_setting('test.business_id')::uuid and source_type='ledger_entry'),
  3, 'Debt, discount, and payment each produce a journal entry'
);
select is(
  coalesce((select count(*)::integer from public.journal_entries je join public.journal_entry_lines jl on jl.journal_entry_id=je.id where je.business_id=current_setting('test.business_id')::uuid group by je.id having sum(jl.debit_amount)<>sum(jl.credit_amount)),0),
  0, 'Every system journal entry is balanced: total debit equals total credit'
);
select is(
  (select total_debits from public.account_trial_balance where business_id=current_setting('test.business_id')::uuid and account_code='5100'),
  20.0000::numeric, 'A customer discount debits the sales-discount expense account'
);
select is(
  (select signed_balance from public.account_trial_balance where business_id=current_setting('test.business_id')::uuid and account_code='1100'),
  (-50.0000)::numeric, 'Accounts receivable can carry a credit balance for a customer advance'
);
select is(
  (select amount_customer_owes from public.business_customer_account_positions where business_customer_id=current_setting('test.business_customer_id')::uuid),
  0.0000::numeric, 'The customer owes nothing after payment and discount'
);
select is(
  (select amount_business_owes_customer from public.business_customer_account_positions where business_customer_id=current_setting('test.business_customer_id')::uuid),
  50.0000::numeric, 'The customer credit (amount owed by the business) is shown separately'
);

select set_config('test.manual_journal_id',public.post_manual_journal(
  current_setting('test.business_id')::uuid,current_date,'Balanced management adjustment',
  jsonb_build_array(
    jsonb_build_object('account_id',(select id from public.chart_of_accounts where business_id=current_setting('test.business_id')::uuid and account_code='1000'),'debit_amount',5,'credit_amount',0,'description','Cash correction'),
    jsonb_build_object('account_id',(select id from public.chart_of_accounts where business_id=current_setting('test.business_id')::uuid and account_code='4000'),'debit_amount',0,'credit_amount',5,'description','Revenue correction')
  ),'ADJ-TEST-1'
)::text,true);
select is(
  (select count(*)::integer from public.journal_entry_lines where journal_entry_id=current_setting('test.manual_journal_id')::uuid),
  2, 'A manual journal accepts only its explicit balanced lines'
);
select is(
  coalesce((select count(*)::integer from public.journal_entries je join public.journal_entry_lines jl on jl.journal_entry_id=je.id where je.business_id=current_setting('test.business_id')::uuid group by je.id having sum(jl.debit_amount)<>sum(jl.credit_amount)),0),
  0, 'The manual adjustment preserves the double-entry balance invariant'
);

select * from finish();
rollback;

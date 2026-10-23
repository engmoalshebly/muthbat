-- 037_overpayment_policy.sql
-- v1 policy: a payment above the outstanding balance is accepted by default and
-- becomes a customer credit ("له دفعة مقدمة"). A store can switch this off
-- (allow_customer_credit_balance = false), after which it is rejected with a
-- stable error message that the mobile client maps to user text.
begin;
select plan(7);

insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
  ('00000000-0000-0000-0000-000000000000','a7111111-1111-1111-1111-111111111111','authenticated','authenticated','op-merchant@example.test','not-used',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','a7222222-2222-2222-2222-222222222222','authenticated','authenticated','op-customer@example.test','not-used',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());

select set_config('test.customer_id',(select id::text from public.customers where user_id='a7222222-2222-2222-2222-222222222222'),true);

set local role authenticated;
select set_config('request.jwt.claim.sub','a7111111-1111-1111-1111-111111111111',true);
select set_config('test.biz',public.create_business('Overpayment Store','retail','YER')::text,true);
select set_config('test.bc',public.add_business_customer(current_setting('test.biz')::uuid,current_setting('test.customer_id')::uuid,'OP Customer',null)::text,true);
select set_config('test.link',public.request_customer_link(current_setting('test.bc')::uuid)::text,true);
select set_config('request.jwt.claim.sub','a7222222-2222-2222-2222-222222222222',true);
select public.respond_link_request(current_setting('test.link')::uuid,true);
select set_config('request.jwt.claim.sub','a7111111-1111-1111-1111-111111111111',true);

select set_config('test.debt_id',public.create_ledger_entry(
  p_business_customer_id := current_setting('test.bc')::uuid,
  p_entry_type := 'debt', p_amount := 100,
  p_description := 'Overpayment policy debt',
  p_client_request_id := 'a7aaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaa1')::text,true);

select is(
  (select allow_customer_credit_balance from public.business_accounting_settings
    where business_id = current_setting('test.biz')::uuid),
  true, 'OP-01: customer credit is allowed by default');

select lives_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''payment'', p_amount := 150, p_description := ''Payment above balance'', p_client_request_id := ''a7aaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaa2'')',
  current_setting('test.bc')),
  'OP-02: a payment above the balance is accepted by default');

select is(
  (select sum(case when direction='debit' then amount else -amount end)
     from public.ledger_entries
    where business_customer_id = current_setting('test.bc')::uuid),
  -50.0000::numeric, 'OP-03: the excess is kept as a 50 credit in favour of the customer');

reset role;
update public.business_accounting_settings set allow_customer_credit_balance = false
 where business_id = current_setting('test.biz')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub','a7111111-1111-1111-1111-111111111111',true);

select throws_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''payment'', p_amount := 10, p_description := ''Payment on a credit balance'', p_client_request_id := ''a7aaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaa3'')',
  current_setting('test.bc')),
  null, 'Payment exceeds current balance',
  'OP-04: with credit disabled a payment on a credit balance is rejected with the stable message');

select lives_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''debt'', p_amount := 80, p_description := ''Debt to clear credit'', p_client_request_id := ''a7aaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaa4'')',
  current_setting('test.bc')),
  'OP-05: new debt is still accepted when credit is disabled');

select throws_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''payment'', p_amount := 31, p_description := ''Payment above 30 balance'', p_client_request_id := ''a7aaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaa5'')',
  current_setting('test.bc')),
  null, 'Payment exceeds current balance',
  'OP-06: with credit disabled a payment above the 30 balance is rejected');

select lives_ok(format(
  'select public.create_ledger_entry(p_business_customer_id := %L::uuid, p_entry_type := ''payment'', p_amount := 30, p_description := ''Exact settlement'', p_client_request_id := ''a7aaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaa6'')',
  current_setting('test.bc')),
  'OP-07: an exact settlement is accepted');

select * from finish();
rollback;

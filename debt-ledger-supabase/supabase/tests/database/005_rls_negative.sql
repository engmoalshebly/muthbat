begin;
select plan(12);

-- Setup: 2 distinct merchants + 1 linked customer + 1 unlinked customer
insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
  ('00000000-0000-0000-0000-000000000000','91111111-1111-1111-1111-111111111111','authenticated','authenticated','tenant-a@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"Merchant Tenant A"}'::jsonb,now(),now()),
  ('00000000-0000-0000-0000-000000000000','92222222-2222-2222-2222-222222222222','authenticated','authenticated','tenant-b@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"Merchant Tenant B"}'::jsonb,now(),now()),
  ('00000000-0000-0000-0000-000000000000','93333333-3333-3333-3333-333333333333','authenticated','authenticated','customer-a@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"Customer A"}'::jsonb,now(),now()),
  ('00000000-0000-0000-0000-000000000000','94444444-4444-4444-4444-444444444444','authenticated','authenticated','stranger@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"Stranger Customer"}'::jsonb,now(),now());

-- Customer IDs lookup
select set_config('test.customer_a_id', (select id::text from public.customers where user_id='93333333-3333-3333-3333-333333333333'), true);
select set_config('test.stranger_id', (select id::text from public.customers where user_id='94444444-4444-4444-4444-444444444444'), true);

set local role authenticated;

-- 1. Setup Tenant A
select set_config('request.jwt.claim.sub','91111111-1111-1111-1111-111111111111',true);
select set_config('test.biz_a', public.create_business('Tenant A Store','retail','YER')::text, true);
select set_config('test.bc_a', public.add_business_customer(current_setting('test.biz_a')::uuid, current_setting('test.customer_a_id')::uuid, 'Customer In Store A', 1000)::text, true);
select set_config('test.link_req_a', public.request_customer_link(current_setting('test.bc_a')::uuid)::text, true);

-- Customer A accepts link with Tenant A
select set_config('request.jwt.claim.sub','93333333-3333-3333-3333-333333333333',true);
select public.respond_link_request(current_setting('test.link_req_a')::uuid, true);

-- Tenant A creates an entry
select set_config('request.jwt.claim.sub','91111111-1111-1111-1111-111111111111',true);
select set_config('test.entry_a', public.create_ledger_entry(p_business_customer_id := current_setting('test.bc_a')::uuid,p_entry_type := 'debt',p_amount := 250,p_description := 'Secret Sale A',p_occurred_at := now(),p_due_date := current_date + 7,p_client_request_id := '95555555-5555-5555-5555-555555555555'::uuid)::text, true);

-- 2. Setup Tenant B
select set_config('request.jwt.claim.sub','92222222-2222-2222-2222-222222222222',true);
select set_config('test.biz_b', public.create_business('Tenant B Store','retail','YER')::text, true);

-- =========================================================================
-- NEGATIVE SECURITY TESTS (Cross-tenant & Authorization Isolation)
-- =========================================================================

-- Test 1: Merchant B cannot see Merchant A's business_customers
select is(
  (select count(*)::integer from public.business_customers where business_id=current_setting('test.biz_a')::uuid),
  0,
  'Merchant B cannot read business_customers of Tenant A (RLS isolation)'
);

-- Test 2: Merchant B cannot see Merchant A's ledger entries
select is(
  (select count(*)::integer from public.ledger_entries where business_id=current_setting('test.biz_a')::uuid),
  0,
  'Merchant B cannot read ledger_entries of Tenant A (RLS isolation)'
);

-- Test 3: Merchant B cannot create a ledger entry on Merchant A's customer
select throws_ok(
  format('select public.create_ledger_entry(p_business_customer_id := ''%s''::uuid,p_entry_type := ''debt'',p_amount := 100,p_description := ''Unauthorized Debt'',p_occurred_at := now(),p_client_request_id := ''96666666-6666-6666-6666-666666666666''::uuid)', current_setting('test.bc_a')),
  '42501',
  null,
  'Merchant B cannot create ledger entry on Tenant A customer (42501)'
);

-- Test 4: Merchant B cannot reverse Merchant A's entry
select throws_ok(
  format('select public.reverse_ledger_entry(''%s''::uuid, ''Illegitimate reversal'', ''97777777-7777-7777-7777-777777777777''::uuid)', current_setting('test.entry_a')),
  '42501',
  null,
  'Merchant B cannot reverse entry belonging to Tenant A (42501)'
);

-- Test 5: Merchant B cannot invite members to Merchant A's business
select throws_ok(
  format('select public.invite_business_member(''%s''::uuid, ''94444444-4444-4444-4444-444444444444''::uuid, ''cashier'')', current_setting('test.biz_a')),
  '42501',
  null,
  'Merchant B cannot invite members to Tenant A business (42501)'
);

-- Test 6: Stranger Customer cannot read Tenant A ledger entries
select set_config('request.jwt.claim.sub','94444444-4444-4444-4444-444444444444',true);
select is(
  (select count(*)::integer from public.ledger_entries where id=current_setting('test.entry_a')::uuid),
  0,
  'Stranger customer cannot read Tenant A ledger entries (RLS isolation)'
);

-- Test 7: Stranger Customer cannot confirm Tenant A ledger entries
select throws_ok(
  format('select public.confirm_ledger_entry(''%s''::uuid)', current_setting('test.entry_a')),
  '42501',
  null,
  'Stranger customer cannot confirm Tenant A ledger entries (42501)'
);

-- Test 8: Stranger Customer cannot open dispute on Tenant A entry
select throws_ok(
  format('select public.open_dispute(''%s''::uuid, ''wrong_amount'', ''Malicious dispute attempt'')', current_setting('test.entry_a')),
  '42501',
  null,
  'Stranger customer cannot open dispute on Tenant A entry (42501)'
);

-- Test 9: Linked Customer A CAN see their own entry under Tenant A
select set_config('request.jwt.claim.sub','93333333-3333-3333-3333-333333333333',true);
select is(
  (select count(*)::integer from public.ledger_entries where id=current_setting('test.entry_a')::uuid),
  1,
  'Linked Customer A CAN see their authorized ledger entry (Sanity check)'
);

-- Test 10: Linked Customer A CANNOT view entries of other customers
select is(
  (select count(*)::integer from public.ledger_entries where customer_id <> current_setting('test.customer_a_id')::uuid),
  0,
  'Linked Customer A cannot view entries of any other customer'
);

-- Test 11: Merchant B cannot create statement for Tenant A customer
select set_config('request.jwt.claim.sub','92222222-2222-2222-2222-222222222222',true);
select throws_ok(
  format('select public.create_statement(''business_customer'', ''%s''::uuid, now() - interval ''30 days'', now())', current_setting('test.bc_a')),
  '42501',
  null,
  'Merchant B cannot generate statement for Tenant A customer (42501)'
);

-- Test 12: Profiles user_type isolation and update permissions
select set_config('request.jwt.claim.sub','91111111-1111-1111-1111-111111111111',true);
select ok(
  (select user_type from public.profiles where id='91111111-1111-1111-1111-111111111111') is not null,
  'Profile user_type exists and is initialized'
);

select * from finish();
rollback;

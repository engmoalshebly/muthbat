begin;
select plan(11);

-- Fixed IDs make this test deterministic. The surrounding transaction is rolled back.
insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
  ('00000000-0000-0000-0000-000000000000','81111111-1111-1111-1111-111111111111','authenticated','authenticated','workflow-merchant@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"Workflow Merchant"}'::jsonb,now(),now()),
  ('00000000-0000-0000-0000-000000000000','82222222-2222-2222-2222-222222222222','authenticated','authenticated','workflow-customer@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"Workflow Customer"}'::jsonb,now(),now()),
  ('00000000-0000-0000-0000-000000000000','83333333-3333-3333-3333-333333333333','authenticated','authenticated','workflow-cashier@example.test','not-used',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{"display_name":"Workflow Cashier"}'::jsonb,now(),now());

-- This lookup intentionally happens before assuming the API role, because a merchant
-- cannot read a different customer's global identity under RLS.
select set_config('test.customer_id',(select id::text from public.customers where user_id='82222222-2222-2222-2222-222222222222'),true);

set local role authenticated;

-- Merchant creates a business, then adds a registered customer and requests consented linking.
select set_config('request.jwt.claim.sub','81111111-1111-1111-1111-111111111111',true);
select set_config('test.business_id',public.create_business('Workflow Store','retail','YER')::text,true);
select set_config('test.business_customer_id',public.add_business_customer(current_setting('test.business_id')::uuid,current_setting('test.customer_id')::uuid,'Workflow Customer',500)::text,true);
select set_config('test.link_request_id',public.request_customer_link(current_setting('test.business_customer_id')::uuid)::text,true);

select set_config('request.jwt.claim.sub','82222222-2222-2222-2222-222222222222',true);
select public.respond_link_request(current_setting('test.link_request_id')::uuid,true);
select is(
  (select link_status::text from public.business_customers where id=current_setting('test.business_customer_id')::uuid),
  'linked', 'Customer link is accepted before customer financial access is allowed'
);

-- Debt and payment use stable client request IDs, so a retried offline payment is not duplicated.
select set_config('request.jwt.claim.sub','81111111-1111-1111-1111-111111111111',true);
select set_config('test.debt_id',public.create_ledger_entry(current_setting('test.business_customer_id')::uuid,'debt',100,'Invoice WF-100',now(),current_date + 14,null,'84444444-4444-4444-4444-444444444444')::text,true);
select set_config('test.payment_id',public.create_ledger_entry(current_setting('test.business_customer_id')::uuid,'payment',20,'Payment WF-20',now(),null,null,'85555555-5555-5555-5555-555555555555')::text,true);
select is(
  public.create_ledger_entry(current_setting('test.business_customer_id')::uuid,'payment',20,'Payment WF-20',now(),null,null,'85555555-5555-5555-5555-555555555555'),
  current_setting('test.payment_id')::uuid, 'A repeated client request returns the original payment'
);
select is(
  (select count(*)::integer from public.ledger_entries where business_customer_id=current_setting('test.business_customer_id')::uuid),
  2, 'Duplicate payment retry does not create a second ledger entry'
);

-- The linked customer can confirm an entry and open a dispute; merchant resolves it with a correction.
select set_config('request.jwt.claim.sub','82222222-2222-2222-2222-222222222222',true);
select public.confirm_ledger_entry(current_setting('test.debt_id')::uuid);
select is(
  (select confirmation_status::text from public.ledger_entry_state where entry_id=current_setting('test.debt_id')::uuid),
  'confirmed', 'Customer confirmation changes the entry state'
);
select set_config('test.dispute_id',public.open_dispute(current_setting('test.debt_id')::uuid,'wrong_amount','The claimed amount is too high')::text,true);

select set_config('request.jwt.claim.sub','81111111-1111-1111-1111-111111111111',true);
select public.resolve_dispute(current_setting('test.dispute_id')::uuid,'partially_accepted','Amount corrected after review',80);
select is(
  (select status::text from public.dispute_state where dispute_id=current_setting('test.dispute_id')::uuid),
  'partially_accepted', 'Partial dispute resolution reaches its terminal state'
);
select is(
  (select current_balance from public.business_customer_balances where business_customer_id=current_setting('test.business_customer_id')::uuid),
  60.0000::numeric, 'Ledger balance equals debt 100 minus payment 20 minus reversal 100 plus corrected debt 80'
);
select is(
  (select count(*)::integer from public.ledger_entries where business_customer_id=current_setting('test.business_customer_id')::uuid),
  4, 'Dispute correction writes an immutable reversal and corrected entry'
);

-- Statement output is an immutable snapshot of the append-only ledger.
select set_config('test.statement_id',public.create_statement('business_customer',current_setting('test.business_customer_id')::uuid,now()-interval '1 day',now()+interval '1 day')::text,true);
select is(
  (select closing_balance from public.statements where id=current_setting('test.statement_id')::uuid),
  60.0000::numeric, 'Statement closing balance matches the live computed balance'
);
select is(
  (select count(*)::integer from public.statement_items where statement_id=current_setting('test.statement_id')::uuid),
  4, 'Statement contains each ledger event in the selected period'
);

-- An admin/owner controlled invitation grants a scoped operational role only after acceptance.
select set_config('test.invite_id',public.invite_business_member(current_setting('test.business_id')::uuid,'83333333-3333-3333-3333-333333333333','cashier')::text,true);
select set_config('request.jwt.claim.sub','83333333-3333-3333-3333-333333333333',true);
select public.respond_business_member_invite(current_setting('test.invite_id')::uuid,true);
select is(
  (select status::text from public.business_member_invites where id=current_setting('test.invite_id')::uuid),
  'accepted', 'Employee invitation has an auditable acceptance state'
);
select is(
  (select role::text from public.business_members where business_id=current_setting('test.business_id')::uuid and user_id='83333333-3333-3333-3333-333333333333'),
  'cashier', 'Accepted invitation creates an active scoped member role'
);

select * from finish();
rollback;

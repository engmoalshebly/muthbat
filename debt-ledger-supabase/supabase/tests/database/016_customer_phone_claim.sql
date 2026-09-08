begin;
select plan(6);
select ok(not has_function_privilege('anon', 'public.service_claim_customer_phone(uuid,text,bytea,text,smallint)', 'execute'), 'Anonymous cannot claim customer phone');
select ok(not has_function_privilege('authenticated', 'public.service_claim_customer_phone(uuid,text,bytea,text,smallint)', 'execute'), 'Client cannot claim arbitrary phone hash');
select ok(has_function_privilege('service_role', 'public.service_claim_customer_phone(uuid,text,bytea,text,smallint)', 'execute'), 'Verified server can claim phone');
select ok(not has_function_privilege('anon', 'public.customer_pending_link_requests()', 'execute'), 'Anonymous cannot read invitations');
select ok(has_function_privilege('authenticated', 'public.customer_pending_link_requests()', 'execute'), 'Customer can request own invitation metadata');
select throws_ok(
  $$select public.service_claim_customer_phone('00000000-0000-0000-0000-000000000000',repeat('a',64),decode('00','hex'),'1234',1::smallint)$$,
  '42501', 'verified_phone_required', 'Missing verified identity is rejected'
);
select * from finish();
rollback;

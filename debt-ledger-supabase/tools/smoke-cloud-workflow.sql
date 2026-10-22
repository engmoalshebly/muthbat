-- Transaction-only smoke check. All synthetic accounts and entries roll back.
begin;

insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
  ('00000000-0000-0000-0000-000000000000','a831e012-824a-4f40-8c5f-2cf8485964f1',
   'authenticated','authenticated','cloud-smoke-owner@example.test','not-a-login-password',now(),
   '{"provider":"email","providers":["email"]}',
   '{"display_name":"Cloud Smoke Owner"}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','b831e012-824a-4f40-8c5f-2cf8485964f2',
   'authenticated','authenticated','cloud-smoke-stranger@example.test','not-a-login-password',now(),
   '{"provider":"email","providers":["email"]}',
   '{"display_name":"Cloud Smoke Stranger"}',now(),now());

set local role authenticated;
select set_config('request.jwt.claim.sub','a831e012-824a-4f40-8c5f-2cf8485964f1',true);
select set_config('smoke.business',public.create_business('Cloud Smoke Store','retail','YER')::text,true);
select set_config('smoke.customer',public.add_business_customer(
  current_setting('smoke.business')::uuid,
  (select id from public.customers where user_id='a831e012-824a-4f40-8c5f-2cf8485964f1'),
  'Cloud Smoke Customer'
)::text,true);

select public.create_ledger_entry(
  p_business_customer_id=>current_setting('smoke.customer')::uuid,
  p_entry_type=>'debt',p_amount=>100,p_description=>'Cloud smoke debt',
  p_client_request_id=>'c831e012-824a-4f40-8c5f-2cf8485964f3'
);
select public.create_ledger_entry(
  p_business_customer_id=>current_setting('smoke.customer')::uuid,
  p_entry_type=>'payment',p_amount=>25,p_description=>'Cloud smoke payment',
  p_client_request_id=>'d831e012-824a-4f40-8c5f-2cf8485964f4'
);
-- Retry the same payment: must not post twice.
select public.create_ledger_entry(
  p_business_customer_id=>current_setting('smoke.customer')::uuid,
  p_entry_type=>'payment',p_amount=>25,p_description=>'Cloud smoke payment',
  p_client_request_id=>'d831e012-824a-4f40-8c5f-2cf8485964f4'
);
set constraints all immediate;

do $$
begin
  if (select count(*) from public.ledger_timeline
      where business_id=current_setting('smoke.business')::uuid) <> 2 then
    raise exception 'Smoke check failed: duplicate retry or missing timeline entry';
  end if;
  if (select current_balance from public.business_customer_balances
      where business_customer_id=current_setting('smoke.customer')::uuid
        and currency_code='YER') is distinct from 75::numeric then
    raise exception 'Smoke check failed: expected balance 75';
  end if;
  if exists(select 1 from public.accounting_reconciliation
            where business_id=current_setting('smoke.business')::uuid and not is_reconciled) then
    raise exception 'Smoke check failed: accounting mismatch';
  end if;
end $$;

select set_config('request.jwt.claim.sub','b831e012-824a-4f40-8c5f-2cf8485964f2',true);
do $$
begin
  if exists(select 1 from public.ledger_timeline
            where business_id=current_setting('smoke.business')::uuid) then
    raise exception 'Smoke check failed: cross-account timeline disclosure';
  end if;
end $$;

reset role;
rollback;

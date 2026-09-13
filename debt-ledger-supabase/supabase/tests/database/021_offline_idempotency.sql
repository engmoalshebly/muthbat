begin;
select plan(4);

insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
  ('00000000-0000-0000-0000-000000000000','b5111111-1111-4111-8111-111111111111','authenticated','authenticated','offline-merchant@example.test','not-used',now(),'{}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','b5222222-2222-4222-8222-222222222222','authenticated','authenticated','offline-customer@example.test','not-used',now(),'{}','{}',now(),now());

select set_config('test.customer_id',(select id::text from public.customers where user_id='b5222222-2222-4222-8222-222222222222'),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','b5111111-1111-4111-8111-111111111111',true);
select set_config('test.business_id',public.create_business('Offline Idempotency','retail','USD')::text,true);
select set_config('test.bc_id',public.add_business_customer(current_setting('test.business_id')::uuid,current_setting('test.customer_id')::uuid,'Offline Customer',null)::text,true);

create temporary table offline_requests(sequence integer primary key,request_id uuid not null,entry_id uuid not null);
do $$
declare i integer; request uuid; first_id uuid; duplicate_id uuid;
begin
  for i in 1..100 loop
    request:=gen_random_uuid();
    first_id:=public.create_ledger_entry(
      current_setting('test.bc_id')::uuid,'debt',i::numeric/100,
      'offline operation '||i,p_client_request_id:=request,p_currency_code:='USD'
    );
    duplicate_id:=public.create_ledger_entry(
      current_setting('test.bc_id')::uuid,'debt',i::numeric/100,
      'offline operation '||i,p_client_request_id:=request,p_currency_code:='USD'
    );
    if first_id<>duplicate_id then raise exception 'idempotency result mismatch'; end if;
    insert into offline_requests values(i,request,first_id);
  end loop;
end $$;

select is((select count(*)::int from public.ledger_entries where business_customer_id=current_setting('test.bc_id')::uuid),100,'100 offline commands create exactly 100 ledger entries after duplicate delivery');
select is((select count(*)::int from public.command_receipts where idempotency_key in (select request_id from offline_requests)),100,'every client request has exactly one receipt');
select is((select count(*)::int from public.journal_entries where source_ledger_entry_id in (select entry_id from offline_requests)),100,'every accepted entry has exactly one journal');
select ok(not exists(select 1 from public.accounting_reconciliation where business_id=current_setting('test.business_id')::uuid and not is_reconciled),'the replayed batch remains fully reconciled');

select * from finish();
rollback;

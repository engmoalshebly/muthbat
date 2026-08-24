begin;
select plan(10);

select has_table('public','businesses','Business tenancy table exists');
select has_table('public','business_customers','Tenant-safe customer bridge exists');
select has_table('public','ledger_entries','Immutable ledger table exists');
select has_table('public','disputes','Dispute table exists');
select has_table('public','command_receipts','Offline command receipt table exists');
select has_table('public','automation_rules','Automation rule table exists');
select has_table('public','upload_sessions','Secure upload-session table exists');
select ok(exists(select 1 from pg_policies where schemaname='public' and tablename='ledger_entries' and policyname='ledger_entries_select_allowed'),'Ledger read policy exists');
select ok(exists(select 1 from pg_policies where schemaname='public' and tablename='business_customers' and policyname='business_customers_select_allowed'),'Customer bridge read policy exists');
select ok(exists(select 1 from pg_policies where schemaname='public' and tablename='command_receipts' and policyname='command_receipts_own_select'),'Offline receipt policy exists');

select * from finish();
rollback;

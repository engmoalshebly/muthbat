-- P1 contract checks. Run with pgTAP in CI after migrations.
select plan(15);

select has_table('public','currencies','Official currency catalog exists');
select has_column('public','currencies','code','Currency code exists');
select has_column('public','currencies','decimal_scale','Currency decimal scale exists');
select has_column('public','business_accounting_settings','bank_account_id','Bank control account is configured');
select has_column('public','ledger_entries','amount','Ledger amount exists');
select ok((select data_type='numeric' and numeric_scale=4 from information_schema.columns where table_schema='public' and table_name='ledger_entries' and column_name='amount'),'Ledger amount is numeric(20,4)');
select has_view('public','business_customer_balances','Customer balances view exists');
select has_column('public','business_customer_balances','gross_overdue_debits','Overdue balance is exposed');
select has_view('public','account_trial_balance','Trial balance view exists');
select has_column('public','account_trial_balance','currency_code','Trial balance is currency scoped');
select has_view('public','reconciliation_customer_ar','Reconciliation view exists');
select has_column('public','reconciliation_customer_ar','currency_code','Reconciliation is currency scoped');
select ok(exists(select 1 from public.currencies where code='YER' and is_active),'YER is active');
select ok(exists(select 1 from public.currencies where code='SAR' and is_active),'SAR is active');
select ok(exists(select 1 from cron.job where jobname='muthbat-ar-reconciliation-hourly' and active),'AR reconciliation cron is active');

select * from finish();

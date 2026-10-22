-- Read-only verification after applying the application's migrations.
select jsonb_build_object(
  'database', current_database(),
  'applied_migrations', (select count(*) from supabase_migrations.schema_migrations),
  'latest_migration', (select max(version) from supabase_migrations.schema_migrations),
  'public_tables', (select count(*) from pg_tables where schemaname = 'public'),
  'private_tables', (select count(*) from pg_tables where schemaname = 'private'),
  'public_tables_without_rls', (
    select coalesce(jsonb_agg(c.relname), '[]'::jsonb)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
  ),
  'timeline_uses_invoker', (
    select coalesce('security_invoker=true' = any(c.reloptions), false)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'ledger_timeline'
  ),
  'anon_can_read_ledger', has_table_privilege('anon', 'public.ledger_entries', 'SELECT'),
  'authenticated_can_read_ledger', has_table_privilege('authenticated', 'public.ledger_entries', 'SELECT'),
  'anon_can_request_service_otp', has_function_privilege('anon', 'public.service_request_whatsapp_otp(text)', 'EXECUTE'),
  'local_import_version', public.local_notebook_import_version(),
  'unreconciled_currencies', (select count(*) from public.accounting_reconciliation where not is_reconciled),
  'storage_buckets', (select jsonb_agg(jsonb_build_object('id', id, 'public', public)) from storage.buckets)
) as verification;

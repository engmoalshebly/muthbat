-- Timeline readers must obey the RLS policies of the underlying tables.
-- Later CREATE OR REPLACE VIEW migrations omitted this view option.
begin;
alter view public.ledger_timeline set (security_invoker = true);
commit;

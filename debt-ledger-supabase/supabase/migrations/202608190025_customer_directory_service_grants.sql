-- The customer-directory Edge Function uses service_role to create the
-- privacy-preserving customer shell before calling the authenticated RPC.
-- The original default-deny grants removed these table privileges locally.
begin;

grant select, insert on public.customers to service_role;
grant select on public.business_members to service_role;

commit;

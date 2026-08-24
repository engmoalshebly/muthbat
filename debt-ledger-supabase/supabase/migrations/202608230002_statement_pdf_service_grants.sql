-- The PDF renderer uses the service client only after the caller's RLS access
-- has been verified. Grant the minimum read set needed to render the snapshot.
begin;

grant select on public.statements, public.statement_items,
  public.businesses, public.business_customers, public.customers,
  public.profiles to service_role;

commit;

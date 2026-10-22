-- PostgreSQL grants EXECUTE to PUBLIC by default; revoke that implicit path too.
begin;

revoke all on function public.invite_business_member(uuid,uuid,public.business_role,timestamptz)
  from public, anon, authenticated;
revoke all on function public.respond_business_member_invite(uuid,boolean)
  from public, anon, authenticated;

commit;

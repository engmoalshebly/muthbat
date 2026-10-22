-- Teams are intentionally disabled while the product operates per business owner.
-- Preserve history, revoke operational access, and invalidate pending invitations.
begin;

update public.business_member_invites
set status = 'cancelled', updated_at = now()
where status = 'pending';

update public.business_members
set status = 'suspended', updated_at = now()
where role <> 'owner' and status = 'active';

revoke execute on function public.invite_business_member(uuid,uuid,public.business_role,timestamptz)
  from authenticated;
revoke execute on function public.respond_business_member_invite(uuid,boolean)
  from authenticated;

drop policy if exists business_members_select_allowed on public.business_members;
create policy business_members_select_owner_only on public.business_members
for select to authenticated
using (
  user_id = (select auth.uid())
  and role = 'owner'
  and status = 'active'
);

drop policy if exists member_invites_select_allowed on public.business_member_invites;
revoke select on public.business_member_invites from authenticated;

do $$
declare v_job bigint;
begin
  select jobid into v_job from cron.job
  where jobname = 'expire-business-member-invites';
  if v_job is not null then
    perform cron.unschedule(v_job);
  end if;
end $$;

commit;

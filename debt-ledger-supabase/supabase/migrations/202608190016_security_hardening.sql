-- Debt Ledger MVP - Security hardening (fix-plan/03-security-secrets.md, phase zero)
-- 1) Storage: remove SVG from the public business-assets bucket and purge existing SVGs (03-4.3).
-- 2) Attachment authorization: write-role RPCs used by signed-document-upload / finalize-document-upload (03-4.1).
begin;

-- ---------- 1) business-assets bucket: reject SVG (stored XSS in a public bucket) ----------
update storage.buckets
set allowed_mime_types = array['image/jpeg','image/png','image/webp']
where id = 'business-assets';

-- delete from storage.objects where bucket_id = 'business-assets' and metadata->>'mimetype' = 'image/svg+xml';

-- ---------- 2) Attachment authorization (write access, not read access) ----------
-- Ledger entry attachments require a staff write role, matching the ledger-entry
-- creation role matrix (202608140010_double_entry_accounting.sql).
create or replace function private.can_attach_to_ledger_entry(p_entry_id uuid)
returns boolean
language sql stable security definer set search_path=''
as $$
  select (select auth.uid()) is not null and exists (
    select 1
    from public.ledger_entries le
    where le.id = p_entry_id
      and private.is_business_member(le.business_id, array['owner','admin','accountant','cashier']::public.business_role[])
  )
$$;

-- Dispute message attachments require dispute partyship, mirroring the
-- authorization of private.command_add_dispute_message (202608140006).
create or replace function private.can_attach_to_dispute_message(p_message_id uuid)
returns boolean
language sql stable security definer set search_path=''
as $$
  select (select auth.uid()) is not null and exists (
    select 1
    from public.dispute_messages dm
    join public.disputes d on d.id = dm.dispute_id
    join public.ledger_entries le on le.id = d.entry_id
    where dm.id = p_message_id
      and (
        private.is_business_member(d.business_id, array['owner','admin','accountant','collector']::public.business_role[])
        or (
          private.is_customer_owner(d.customer_id)
          and private.can_customer_access_business_customer(le.business_customer_id)
        )
      )
  )
$$;

-- New functions default to EXECUTE for PUBLIC; lock them down, then grant explicitly.
revoke all on function private.can_attach_to_ledger_entry(uuid) from public, anon, authenticated;
revoke all on function private.can_attach_to_dispute_message(uuid) from public, anon, authenticated;
grant execute on function private.can_attach_to_ledger_entry(uuid) to authenticated;
grant execute on function private.can_attach_to_dispute_message(uuid) to authenticated;
grant execute on function private.can_attach_to_ledger_entry(uuid) to service_role;
grant execute on function private.can_attach_to_dispute_message(uuid) to service_role;

commit;

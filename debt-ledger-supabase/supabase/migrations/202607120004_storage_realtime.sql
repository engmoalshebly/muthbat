-- Debt Ledger MVP - Supabase Storage and Realtime configuration
begin;

create or replace function private.try_uuid(p_value text)
returns uuid
language plpgsql immutable
set search_path=''
as $$
begin
  return p_value::uuid;
exception when others then
  return null;
end;
$$;

-- Private-by-default buckets. Business logos may be public assets.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values
  ('business-assets','business-assets',true,5242880,array['image/jpeg','image/png','image/webp','image/svg+xml']),
  ('avatars','avatars',false,5242880,array['image/jpeg','image/png','image/webp']),
  ('ledger-documents','ledger-documents',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf']),
  ('statements','statements',false,10485760,array['application/pdf'])
on conflict (id) do update set
  public=excluded.public,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

-- Business asset path: <business_id>/<file>
create policy business_assets_staff_insert on storage.objects
for insert to authenticated
with check (
  bucket_id='business-assets'
  and (storage.foldername(name))[1] is not null
  and private.is_business_member(private.try_uuid((storage.foldername(name))[1]),array['owner','admin']::public.business_role[])
);
create policy business_assets_staff_update on storage.objects
for update to authenticated
using (
  bucket_id='business-assets'
  and private.is_business_member(private.try_uuid((storage.foldername(name))[1]),array['owner','admin']::public.business_role[])
)
with check (
  bucket_id='business-assets'
  and private.is_business_member(private.try_uuid((storage.foldername(name))[1]),array['owner','admin']::public.business_role[])
);
create policy business_assets_staff_delete on storage.objects
for delete to authenticated
using (
  bucket_id='business-assets'
  and private.is_business_member(private.try_uuid((storage.foldername(name))[1]),array['owner','admin']::public.business_role[])
);

-- Avatar path: <auth_user_id>/<file>
create policy avatars_owner_select on storage.objects
for select to authenticated
using (bucket_id='avatars' and private.try_uuid((storage.foldername(name))[1])=(select auth.uid()));
create policy avatars_owner_insert on storage.objects
for insert to authenticated
with check (bucket_id='avatars' and private.try_uuid((storage.foldername(name))[1])=(select auth.uid()));
create policy avatars_owner_update on storage.objects
for update to authenticated
using (bucket_id='avatars' and private.try_uuid((storage.foldername(name))[1])=(select auth.uid()))
with check (bucket_id='avatars' and private.try_uuid((storage.foldername(name))[1])=(select auth.uid()));
create policy avatars_owner_delete on storage.objects
for delete to authenticated
using (bucket_id='avatars' and private.try_uuid((storage.foldername(name))[1])=(select auth.uid()));

-- Ledger-document uploads should use an Edge Function that issues a signed upload URL.
-- Reads are authorized through the public.files metadata table.
create policy ledger_documents_authorized_select on storage.objects
for select to authenticated
using (
  bucket_id='ledger-documents'
  and exists (
    select 1 from public.files f
    where f.bucket_id=storage.objects.bucket_id
      and f.object_path=storage.objects.name
      and (
        (f.business_id is not null and private.is_business_member(f.business_id,null))
        or (f.customer_id is not null and private.is_customer_owner(f.customer_id))
      )
  )
);

create policy statements_authorized_select on storage.objects
for select to authenticated
using (
  bucket_id='statements'
  and exists (
    select 1 from public.statements s
    where s.pdf_object_path=storage.objects.name
      and (
        private.is_customer_owner(s.customer_id)
        or (s.business_id is not null and private.is_business_member(s.business_id,null))
      )
  )
);

-- Realtime: publish only UI state/notification tables, not sensitive PII tables.
do $$
declare t text;
begin
  foreach t in array array['notifications','customer_link_requests','ledger_entry_state','dispute_state','dispute_messages'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I',t);
    end if;
  end loop;
end $$;

alter table public.notifications replica identity full;
alter table public.customer_link_requests replica identity full;
alter table public.ledger_entry_state replica identity full;
alter table public.dispute_state replica identity full;
alter table public.dispute_messages replica identity full;

commit;

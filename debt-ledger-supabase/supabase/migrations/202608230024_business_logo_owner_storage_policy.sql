begin;

-- يسمح لمالك المنشأة صراحة بإدارة الشعار داخل المسار <business_id>/*.
-- تبقى المطابقة مقيدة بمجلد منشأته، ولا تمنح وصولاً لأي منشأة أخرى.
create policy business_assets_owner_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'business-assets'
  and exists (
    select 1 from public.businesses b
    where b.id = private.try_uuid((storage.foldername(name))[1])
      and b.owner_user_id = (select auth.uid())
  )
);

create policy business_assets_owner_update on storage.objects
for update to authenticated
using (
  bucket_id = 'business-assets'
  and exists (
    select 1 from public.businesses b
    where b.id = private.try_uuid((storage.foldername(name))[1])
      and b.owner_user_id = (select auth.uid())
  )
)
with check (
  bucket_id = 'business-assets'
  and exists (
    select 1 from public.businesses b
    where b.id = private.try_uuid((storage.foldername(name))[1])
      and b.owner_user_id = (select auth.uid())
  )
);

commit;

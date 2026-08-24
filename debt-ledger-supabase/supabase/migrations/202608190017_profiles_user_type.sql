-- Migration: 202608190017_profiles_user_type.sql
-- Description: Adds user_type column to public.profiles and updates handle_new_auth_user trigger
-- Reference: fix-plan/04-auth-system.md §1.2 & fix-plan.md decision 5 (migration sequencing)

begin;

-- 1. Add user_type column to public.profiles
alter table public.profiles
  add column if not exists user_type text not null default 'merchant' check (user_type in ('merchant', 'customer'));

-- 2. Update bootstrap trigger to populate user_type from auth metadata
create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_user_type text;
begin
  v_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    'مستخدم جديد'
  );

  v_user_type := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'user_type'), ''),
    'merchant'
  );

  if v_user_type not in ('merchant', 'customer') then
    v_user_type := 'merchant';
  end if;

  insert into public.profiles(id, display_name, user_type)
  values (new.id, v_name, v_user_type)
  on conflict (id) do update set
    display_name = excluded.display_name,
    user_type = coalesce(public.profiles.user_type, excluded.user_type),
    updated_at = now();

  insert into public.customers(user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

-- 3. Backfill existing profiles from auth.users metadata where present
update public.profiles p
set user_type = (u.raw_user_meta_data ->> 'user_type')
from auth.users u
where p.id = u.id
  and u.raw_user_meta_data ->> 'user_type' in ('merchant', 'customer');

commit;

-- GoTrue stores phone identities without the leading + on some projects.
-- Resolve both canonical E.164 representations without consulting editable
-- user metadata or matching a different phone number.
create or replace function public.service_find_auth_user_by_phone(p_phone text)
returns table(user_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone text := pg_catalog.btrim(p_phone);
  v_matches uuid[];
begin
  if v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'Invalid phone format' using errcode = '22023';
  end if;

  select pg_catalog.array_agg(u.id) into v_matches
  from (
    select id from auth.users
    where phone in (v_phone, pg_catalog.substr(v_phone, 2))
    limit 2
  ) as u;

  if pg_catalog.coalesce(pg_catalog.array_length(v_matches, 1), 0) > 1 then
    raise exception 'Ambiguous phone identity' using errcode = '23505';
  end if;
  if pg_catalog.array_length(v_matches, 1) = 1 then
    user_id := v_matches[1];
    return next;
  end if;
end;
$$;

revoke all on function public.service_find_auth_user_by_phone(text)
  from public, anon, authenticated;
grant execute on function public.service_find_auth_user_by_phone(text)
  to service_role;

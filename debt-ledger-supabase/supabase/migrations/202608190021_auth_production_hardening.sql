-- Production hardening for the WhatsApp authentication flow.
-- Keeps OTP state server-side, enforces a single active challenge per phone,
-- uses cryptographic randomness, and exposes only service-role RPCs.
begin;

create or replace function private.service_request_otp(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e164 text := trim(p_phone);
  v_code text;
  v_code_hash text;
  v_challenge_id uuid;
  v_recent_sent timestamptz;
  v_random bytea;
  v_random_value bigint;
begin
  if v_e164 !~ '^\+[1-9]\d{7,14}$' then
    raise exception 'Invalid phone format; must be E.164' using errcode = '22023';
  end if;

  -- Serialize requests for the same phone so concurrent requests cannot bypass cooldown.
  perform pg_advisory_xact_lock(hashtextextended(v_e164, 0));

  select max(last_sent_at) into v_recent_sent
  from private.otp_challenges
  where phone_e164 = v_e164
    and created_at > (now() - interval '60 seconds');

  if v_recent_sent is not null then
    raise exception 'Please wait 60 seconds before requesting another code.' using errcode = '55000';
  end if;

  -- Generate a six-digit code from cryptographic random bytes, not random().
  v_random := extensions.gen_random_bytes(4);
  v_random_value := get_byte(v_random, 0)::bigint * 16777216
    + get_byte(v_random, 1)::bigint * 65536
    + get_byte(v_random, 2)::bigint * 256
    + get_byte(v_random, 3)::bigint;
  v_code := lpad((100000 + mod(v_random_value, 900000))::text, 6, '0');
  v_code_hash := encode(extensions.digest(v_code, 'sha256'), 'hex');

  -- A new request invalidates an older still-active challenge for this phone.
  update private.otp_challenges
  set consumed_at = now()
  where phone_e164 = v_e164 and consumed_at is null;

  insert into private.otp_challenges (
    phone_e164, code_hash, attempts_left, expires_at, last_sent_at
  ) values (
    v_e164, v_code_hash, 5, now() + interval '5 minutes', now()
  ) returning id into v_challenge_id;

  return jsonb_build_object(
    'challenge_id', v_challenge_id,
    'code', v_code,
    'expires_in_seconds', 300
  );
end;
$$;

create or replace function private.service_revoke_otp(p_challenge_id uuid)
returns boolean
language sql
security definer
set search_path = ''
as $$
  update private.otp_challenges
  set consumed_at = coalesce(consumed_at, now())
  where id = p_challenge_id and consumed_at is null
  returning true;
$$;

-- Avoid exposing auth.users through PostgREST; only the service role can resolve a phone.
create or replace function public.service_find_auth_user_by_phone(p_phone text)
returns table(user_id uuid)
language sql
security definer
set search_path = ''
as $$
  select id from auth.users where phone = trim(p_phone) limit 1;
$$;

create or replace function public.service_revoke_whatsapp_otp(p_challenge_id uuid)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select coalesce(private.service_revoke_otp(p_challenge_id), false);
$$;

revoke all on function private.service_request_otp(text) from public, anon, authenticated;
revoke all on function private.service_revoke_otp(uuid) from public, anon, authenticated;
revoke all on function public.service_find_auth_user_by_phone(text) from public, anon, authenticated;
revoke all on function public.service_revoke_whatsapp_otp(uuid) from public, anon, authenticated;

grant execute on function private.service_request_otp(text) to service_role;
grant execute on function private.service_revoke_otp(uuid) to service_role;
grant execute on function public.service_find_auth_user_by_phone(text) to service_role;
grant execute on function public.service_revoke_whatsapp_otp(uuid) to service_role;

commit;


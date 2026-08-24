-- Migration: 202608190018_openwa_otp_challenges.sql
-- Description: Server-side OTP challenges for WhatsApp via OpenWA.
--   Enforces cryptographic OTP generation, 5-minute TTL, rate limiting, and atomic attempt counting.

begin;

create table if not exists private.otp_challenges (
  id uuid primary key default gen_random_uuid(),
  phone_e164 text not null,
  code_hash text not null,
  attempts_left smallint not null default 5,
  expires_at timestamptz not null default (now() + interval '5 minutes'),
  consumed_at timestamptz,
  last_sent_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists idx_otp_challenges_phone_active
  on private.otp_challenges (phone_e164)
  where consumed_at is null;

-- Request OTP: rate-limits, generates 6-digit code, hashes it, stores challenge, and returns (challenge_id, code)
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
  v_rate_limit_err text;
begin
  -- Validate E.164 phone format: + followed by 8 to 15 digits
  if v_e164 !~ '^\+[1-9]\d{7,14}$' then
    raise exception 'Invalid phone format; must be E.164 (e.g. +967770000000)' using errcode = '22023';
  end if;

  -- 60-second cooldown per phone number
  select max(last_sent_at) into v_recent_sent
  from private.otp_challenges
  where phone_e164 = v_e164
    and created_at > (now() - interval '60 seconds');

  if v_recent_sent is not null then
    raise exception 'Please wait 60 seconds before requesting another code.' using errcode = '55000';
  end if;

  -- Generate 6-digit numeric OTP
  v_code := lpad((floor(random() * 900000) + 100000)::integer::text, 6, '0');
  v_code_hash := encode(extensions.digest(v_code, 'sha256'), 'hex');

  -- Store challenge
  insert into private.otp_challenges (
    phone_e164,
    code_hash,
    attempts_left,
    expires_at,
    last_sent_at
  ) values (
    v_e164,
    v_code_hash,
    5,
    now() + interval '5 minutes',
    now()
  ) returning id into v_challenge_id;

  return jsonb_build_object(
    'challenge_id', v_challenge_id,
    'code', v_code,
    'expires_in_seconds', 300
  );
end;
$$;

-- Verify OTP: atomically checks hash, decreases attempts_left, marks consumed on success
create or replace function private.service_verify_otp(
  p_challenge_id uuid,
  p_code text,
  p_phone text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_challenge private.otp_challenges%rowtype;
  v_input_hash text;
begin
  if p_challenge_id is null or p_code is null or p_phone is null then
    return false;
  end if;

  -- Lock challenge row for atomic evaluation
  select * into v_challenge
  from private.otp_challenges
  where id = p_challenge_id
    and phone_e164 = trim(p_phone)
  for update;

  if not found then
    return false;
  end if;

  -- Check if already consumed, expired, or out of attempts
  if v_challenge.consumed_at is not null or v_challenge.expires_at <= now() or v_challenge.attempts_left <= 0 then
    return false;
  end if;

  -- Decrement attempts left
  update private.otp_challenges
  set attempts_left = attempts_left - 1
  where id = p_challenge_id;

  v_input_hash := encode(extensions.digest(trim(p_code), 'sha256'), 'hex');

  if v_input_hash = v_challenge.code_hash then
    -- Mark challenge as consumed
    update private.otp_challenges
    set consumed_at = now()
    where id = p_challenge_id;

    return true;
  end if;

  return false;
end;
$$;

-- Permissions: revoke from public/anon/authenticated; grant strictly to service_role
revoke all on function private.service_request_otp(text) from public, anon, authenticated;
revoke all on function private.service_verify_otp(uuid, text, text) from public, anon, authenticated;
grant execute on function private.service_request_otp(text) to service_role;
grant execute on function private.service_verify_otp(uuid, text, text) to service_role;

commit;

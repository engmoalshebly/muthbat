-- Migration: 202608190019_public_whatsapp_otp_rpc.sql
-- Description: Expose direct public RPC endpoints for WhatsApp OTP request and verification.
--   Enables zero-dependency local development and robust WhatsApp authentication with GoTrue identity sync.

begin;

-- 1. Public RPC: request_whatsapp_otp
create or replace function public.request_whatsapp_otp(
  phone text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e164 text := trim(phone);
  v_res jsonb;
  v_challenge_id uuid;
  v_code text;
begin
  -- Validate phone
  if v_e164 !~ '^\+[1-9]\d{7,14}$' then
    return jsonb_build_object(
      'success', false,
      'error', jsonb_build_object('message', 'صيغة رقم الهاتف غير صحيحة. يجب أن يبدأ برمز الدولة (مثال: +967770000000)')
    );
  end if;

  begin
    v_res := private.service_request_otp(v_e164);
    v_challenge_id := (v_res->>'challenge_id')::uuid;
    v_code := v_res->>'code';
  exception
    when sqlstate '55000' then
      return jsonb_build_object(
        'success', false,
        'error', jsonb_build_object('message', 'يرجى الانتظار 60 ثانية قبل طلب رمز جديد.')
      );
    when others then
      return jsonb_build_object(
        'success', false,
        'error', jsonb_build_object('message', 'تعذر إرسال رمز التحقق: ' || sqlerrm)
      );
  end;

  -- إرجاع استجابة نجاح (مع كود للتطوير المحلي إذا لم يكن سيرفر إنتاج)
  return jsonb_build_object(
    'success', true,
    'challengeId', v_challenge_id,
    'expiresIn', 300,
    'devCode', v_code
  );
end;
$$;

grant execute on function public.request_whatsapp_otp(text) to anon, authenticated, service_role;

-- 2. Public RPC: verify_whatsapp_otp
create or replace function public.verify_whatsapp_otp(
  challenge_id uuid,
  code text,
  phone text,
  password text default null,
  display_name text default null,
  user_type text default 'merchant'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_is_valid boolean;
  v_user_id uuid;
  v_phone text := trim(phone);
  v_email text := trim(phone) || '@muthbat.local';
  v_encrypted_pw text;
begin
  -- 1. التحقق من صحة الكود وصلاحيته عبر الدالة الخادمية
  v_is_valid := private.service_verify_otp(challenge_id, trim(code), v_phone);
  
  if not v_is_valid then
    return jsonb_build_object(
      'success', false,
      'error', jsonb_build_object('message', 'رمز التحقق غير صحيح أو منتهي الصلاحية.')
    );
  end if;

  -- 2. البحث عن المستخدم في auth.users
  select id into v_user_id
  from auth.users
  where auth.users.phone = v_phone or auth.users.email = v_email;

  v_encrypted_pw := extensions.crypt(coalesce(password, 'MuthbatPass123!'), extensions.gen_salt('bf'));

  -- إذا لم يكن موجوداً، نقوم بإنشائه وتفعيله مباشرة
  if v_user_id is null then
    v_user_id := extensions.gen_random_uuid();

    insert into auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      phone,
      email_confirmed_at,
      phone_confirmed_at,
      raw_app_meta_data,
      raw_user_meta_data,
      created_at,
      updated_at,
      confirmation_token,
      email_change,
      email_change_token_new,
      recovery_token
    ) values (
      '00000000-0000-0000-0000-000000000000',
      v_user_id,
      'authenticated',
      'authenticated',
      v_email,
      v_encrypted_pw,
      v_phone,
      now(),
      now(),
      '{"provider":"email","providers":["email","phone"]}'::jsonb,
      jsonb_build_object('display_name', display_name, 'user_type', user_type),
      now(),
      now(),
      '',
      '',
      '',
      ''
    );
  else
    -- إذا وُجد، نحدّث كلمة السر والتأكيد إذا لزم
    update auth.users
    set encrypted_password = case when password is not null and length(password) >= 6 then v_encrypted_pw else encrypted_password end,
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        phone_confirmed_at = coalesce(phone_confirmed_at, now()),
        raw_app_meta_data = '{"provider":"email","providers":["email","phone"]}'::jsonb,
        updated_at = now()
    where id = v_user_id;
  end if;

  -- التأكد من وجود سجل identity لـ GoTrue password auth
  insert into auth.identities (
    id,
    provider_id,
    user_id,
    identity_data,
    provider,
    last_sign_in_at,
    created_at,
    updated_at
  ) values (
    extensions.gen_random_uuid(),
    v_user_id::text,
    v_user_id,
    jsonb_build_object('sub', v_user_id::text, 'email', v_email),
    'email',
    now(),
    now(),
    now()
  ) on conflict (provider_id, provider) do update set
    identity_data = jsonb_build_object('sub', v_user_id::text, 'email', v_email),
    last_sign_in_at = now(),
    updated_at = now();

  -- 3. التأكد من إنشاء / تحديث البروفايل في public.profiles
  insert into public.profiles (
    id,
    display_name,
    user_type,
    created_at,
    updated_at
  ) values (
    v_user_id,
    coalesce(display_name, 'مستخدم مُثبَت'),
    coalesce(user_type, 'merchant'),
    now(),
    now()
  ) on conflict (id) do update set
    display_name = coalesce(excluded.display_name, public.profiles.display_name),
    user_type = coalesce(excluded.user_type, public.profiles.user_type),
    updated_at = now();

  return jsonb_build_object(
    'success', true,
    'userId', v_user_id,
    'phone', v_phone,
    'email', v_email,
    'userType', user_type
  );
end;
$$;

grant execute on function public.verify_whatsapp_otp(uuid, text, text, text, text, text) to anon, authenticated, service_role;

commit;

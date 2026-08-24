begin;
select plan(8);

select ok(
  to_regprocedure('public.service_find_auth_user_by_phone(text)') is not null,
  'Service-only phone lookup exists'
);
select ok(
  to_regprocedure('public.service_revoke_whatsapp_otp(uuid)') is not null,
  'Service-only OTP revoke exists'
);
select ok(
  not has_function_privilege('anon', 'public.service_find_auth_user_by_phone(text)', 'execute'),
  'Anonymous callers cannot resolve auth users by phone'
);
select ok(
  not has_function_privilege('authenticated', 'public.service_find_auth_user_by_phone(text)', 'execute'),
  'Authenticated callers cannot resolve auth users by phone'
);
select ok(
  has_function_privilege('service_role', 'public.service_find_auth_user_by_phone(text)', 'execute'),
  'Only service role can resolve auth users by phone'
);
select ok(
  not has_function_privilege('anon', 'public.service_request_whatsapp_otp(text)', 'execute'),
  'Anonymous callers cannot request OTP through the service RPC'
);
select ok(
  not has_function_privilege('anon', 'public.service_verify_whatsapp_otp(uuid,text,text)', 'execute'),
  'Anonymous callers cannot verify OTP through the service RPC'
);
select like(
  pg_get_functiondef('private.service_request_otp(text)'::regprocedure),
  '%gen_random_bytes%',
  'OTP generation uses cryptographic random bytes'
);

select * from finish();
rollback;


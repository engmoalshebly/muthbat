-- Replace public OTP RPCs with service-role-only wrappers used by Edge Functions.
-- OTP delivery and account mutation must never be reachable through PostgREST.
begin;

revoke all on function public.request_whatsapp_otp(text) from public, anon, authenticated, service_role;
revoke all on function public.verify_whatsapp_otp(uuid, text, text, text, text, text) from public, anon, authenticated, service_role;
drop function if exists public.request_whatsapp_otp(text);
drop function if exists public.verify_whatsapp_otp(uuid, text, text, text, text, text);

create or replace function public.service_request_whatsapp_otp(p_phone text)
returns jsonb
language sql
security definer
set search_path = ''
as $$ select private.service_request_otp(p_phone); $$;

create or replace function public.service_verify_whatsapp_otp(
  p_challenge_id uuid,
  p_code text,
  p_phone text
)
returns boolean
language sql
security definer
set search_path = ''
as $$ select private.service_verify_otp(p_challenge_id, p_code, p_phone); $$;

revoke all on function public.service_request_whatsapp_otp(text) from public, anon, authenticated;
revoke all on function public.service_verify_whatsapp_otp(uuid, text, text) from public, anon, authenticated;
grant execute on function public.service_request_whatsapp_otp(text) to service_role;
grant execute on function public.service_verify_whatsapp_otp(uuid, text, text) to service_role;

commit;

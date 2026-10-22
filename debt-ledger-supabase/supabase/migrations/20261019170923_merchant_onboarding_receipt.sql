begin;
create table private.business_creation_receipts(
 user_id uuid not null references auth.users(id), request_id uuid not null,
 payload jsonb not null, business_id uuid not null references public.businesses(id),
 primary key(user_id,request_id)
);
alter table private.business_creation_receipts enable row level security;
create index business_creation_receipts_business_idx on private.business_creation_receipts(business_id);
revoke all on private.business_creation_receipts from public,anon,authenticated,service_role;
create function public.create_business_idempotent(p_request_id uuid,p_profile jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_receipt private.business_creation_receipts%rowtype; v_business uuid;
  v_currencies text[];
begin
 if v_user is null or p_request_id is null then raise exception 'Authentication required' using errcode='28000'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_user::text||p_request_id::text,0));
 select * into v_receipt from private.business_creation_receipts where user_id=v_user and request_id=p_request_id;
 if found then
   if v_receipt.payload is distinct from p_profile then raise exception 'Request payload cannot change' using errcode='22023'; end if;
   return v_receipt.business_id;
 end if;
 if length(trim(coalesce(p_profile->>'name',''))) not between 2 and 120
   or length(trim(coalesce(p_profile->>'business_type',''))) not between 2 and 120
   or coalesce(p_profile->>'country_code','YE') !~ '^[A-Z]{2}$'
   or length(coalesce(p_profile->>'city',''))>120 or length(coalesce(p_profile->>'address',''))>500
   or (nullif(p_profile->>'contact_phone','') is not null and p_profile->>'contact_phone' !~ '^\+[1-9][0-9]{7,14}$') then
   raise exception 'Invalid business details' using errcode='22023';
 end if;
 select coalesce(array_agg(value),'{}') into v_currencies
   from jsonb_array_elements_text(coalesce(p_profile->'additional_currencies','[]'));
 if exists(select 1 from unnest(v_currencies) c where not exists(select 1 from public.currencies where code=c and is_active)) then
   raise exception 'Unsupported additional currency' using errcode='22023';
 end if;
 if not exists(select 1 from public.currencies where code=p_profile->>'currency_code' and is_active) then
   raise exception 'Unsupported currency' using errcode='22023';
 end if;
 v_business:=private.command_create_business(p_profile->>'name',p_profile->>'business_type',p_profile->>'currency_code',
   coalesce(p_profile->>'country_code','YE'),p_profile->>'city',p_profile->>'address',v_currencies);
 update public.businesses set contact_phone_display=nullif(p_profile->>'contact_phone','') where id=v_business;
 insert into private.business_creation_receipts values(v_user,p_request_id,p_profile,v_business);
 return v_business;
end $$;
revoke all on function public.create_business_idempotent(uuid,jsonb) from public,anon;
grant execute on function public.create_business_idempotent(uuid,jsonb) to authenticated;
commit;

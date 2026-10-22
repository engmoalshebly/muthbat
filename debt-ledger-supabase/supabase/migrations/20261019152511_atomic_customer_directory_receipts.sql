begin;
create table private.customer_directory_receipts(
  user_id uuid not null references auth.users(id), request_id uuid not null,
  payload jsonb not null, contact jsonb not null, result jsonb,
  primary key(user_id,request_id)
);
alter table private.customer_directory_receipts enable row level security;
revoke all on private.customer_directory_receipts from public,anon,authenticated,service_role;

-- Only the trusted PII boundary may stage encrypted contact data. Retries
-- compare the stable hash, not randomized ciphertext.
create or replace function public.service_prepare_customer_directory(
  p_user_id uuid,p_request_id uuid,p_payload jsonb,p_contact jsonb
) returns void language plpgsql security definer set search_path='' as $$
declare v_existing private.customer_directory_receipts%rowtype;
begin
  if p_request_id is null or p_user_id is null or p_payload ? 'phone' then
    raise exception 'Invalid directory request' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text||p_request_id::text,0));
  select * into v_existing from private.customer_directory_receipts where user_id=p_user_id and request_id=p_request_id;
  if found then
    if v_existing.payload is distinct from p_payload or v_existing.contact->>'phone_hash' is distinct from p_contact->>'phone_hash' then
      raise exception 'Request payload cannot change' using errcode='22023';
    end if;
    return;
  end if;
  insert into private.customer_directory_receipts(user_id,request_id,payload,contact)
    values(p_user_id,p_request_id,p_payload,p_contact);
end; $$;
revoke all on function public.service_prepare_customer_directory(uuid,uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.service_prepare_customer_directory(uuid,uuid,jsonb,jsonb) to service_role;

create or replace function public.complete_customer_directory(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_request private.customer_directory_receipts%rowtype; v_business uuid;
  v_customer uuid; v_bc uuid; v_link uuid; v_registered boolean; v_global text;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='28000'; end if;
  select * into v_request from private.customer_directory_receipts
    where user_id=auth.uid() and request_id=p_request_id for update;
  if not found then raise exception 'Preparation required' using errcode='42501'; end if;
  v_business := (v_request.payload->>'businessId')::uuid;
  if not private.is_business_member(v_business,array['owner','admin','accountant','cashier']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  if v_request.result is not null then return v_request.result; end if;
  if length(trim(coalesce(v_request.payload->>'localDisplayName',''))) not between 2 and 120
    or length(coalesce(v_request.payload->>'localNote',''))>500
    or coalesce((v_request.payload->>'creditLimit')::numeric,0)<0
    or coalesce((v_request.payload->>'defaultDueDays')::integer,0) not between 0 and 3650 then
    raise exception 'Invalid customer details' using errcode='22023';
  end if;
  if v_request.contact->>'phone_hash' is not null then
    select customer_id into v_customer from public.service_resolve_customer_phone(
      v_request.contact->>'phone_hash',(v_request.contact->>'phone_ciphertext')::bytea,
      v_request.contact->>'phone_last4',(v_request.contact->>'key_version')::smallint);
    v_bc:=public.add_business_customer(v_business,v_customer,v_request.payload->>'localDisplayName',
      (v_request.payload->>'creditLimit')::numeric,(v_request.payload->>'defaultDueDays')::smallint);
  else
    v_bc:=private.command_create_business_customer_direct(v_business,v_request.payload->>'localDisplayName',
      (v_request.payload->>'creditLimit')::numeric,(v_request.payload->>'defaultDueDays')::smallint);
    select customer_id into v_customer from public.business_customers where id=v_bc;
  end if;
  update public.business_customers set local_note=nullif(trim(v_request.payload->>'localNote'),'') where id=v_bc;
  select user_id is not null,global_code into v_registered,v_global from public.customers where id=v_customer;
  if coalesce((v_request.payload->>'requestLink')::boolean,false) and v_registered then
    v_link:=public.request_customer_link(v_bc);
  end if;
  update private.customer_directory_receipts set result=jsonb_build_object(
    'businessCustomerId',v_bc,'linkRequestId',v_link,'isRegistered',v_registered,
    'phoneLast4',v_request.contact->>'phone_last4','globalCode',v_global)
    where user_id=auth.uid() and request_id=p_request_id returning result into v_request.result;
  return v_request.result;
end; $$;
revoke all on function public.complete_customer_directory(uuid) from public,anon;
grant execute on function public.complete_customer_directory(uuid) to authenticated;
commit;

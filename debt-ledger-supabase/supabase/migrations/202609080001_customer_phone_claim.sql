begin;

-- Trusted Edge-only operation. Preserve the old customer id so immutable
-- ledger entries and references do not need to be rewritten.
create or replace function public.service_claim_customer_phone(
  p_user_id uuid, p_phone_hash text, p_phone_ciphertext bytea,
  p_phone_last4 text, p_key_version smallint default 1
)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  v_current public.customers%rowtype;
  v_target public.customers%rowtype;
  v_bc record;
  v_request uuid;
begin
  if p_phone_hash is null or length(p_phone_hash)<16 then raise exception 'invalid_phone_hash'; end if;
  if not exists(select 1 from auth.users where id=p_user_id and phone_confirmed_at is not null
    and coalesce(raw_app_meta_data->>'phone_verification_bypassed','false')<>'true') then
    raise exception 'verified_phone_required' using errcode='42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('customer-phone:'||p_phone_hash,0));
  select * into v_current from public.customers where user_id=p_user_id and status='active' for update;
  if not found then raise exception 'customer_not_found'; end if;
  select c.* into v_target from public.customers c join private.customer_contacts cc on cc.customer_id=c.id
    where cc.phone_hash=p_phone_hash for update of c;
  if found and v_target.id<>v_current.id then
    if v_target.user_id is not null or v_target.status<>'active' then
      raise exception 'phone_ownership_conflict' using errcode='23505';
    end if;
    -- Never silently merge a previously used personal identity.
    if exists(select 1 from public.business_customers where customer_id=v_current.id)
      or exists(select 1 from public.ledger_entries where customer_id=v_current.id)
      or exists(select 1 from private.customer_contacts where customer_id=v_current.id and phone_hash is not null) then
      raise exception 'customer_merge_requires_review' using errcode='23505';
    end if;
    update public.customers set user_id=null,status='merged',merged_into_customer_id=v_target.id where id=v_current.id;
    update public.customers set user_id=p_user_id where id=v_target.id;
    v_current.id:=v_target.id;
  end if;
  perform private.service_upsert_customer_contact(v_current.id,p_phone_hash,p_phone_ciphertext,p_phone_last4,now(),p_key_version);
  for v_bc in select bc.id,b.owner_user_id from public.business_customers bc
    join public.businesses b on b.id=bc.business_id
    where bc.customer_id=v_current.id and bc.link_status='unlinked' and not bc.is_archived and b.status='active'
    for update of bc loop
    if not exists(select 1 from public.customer_link_requests where business_customer_id=v_bc.id) then
      insert into public.customer_link_requests(business_customer_id,requested_by_user_id,target_customer_id)
      values(v_bc.id,v_bc.owner_user_id,v_current.id) returning id into v_request;
      update public.business_customers set link_status='pending' where id=v_bc.id;
      perform private.enqueue_notification(p_user_id,'link_request','بقالة تريد ربط حسابك','راجع طلب الربط. قبوله لا يعني تأكيد الديون.','link_request',v_request,'{}');
    end if;
  end loop;
  return v_current.id;
end;
$$;
revoke all on function public.service_claim_customer_phone(uuid,text,bytea,text,smallint) from public,anon,authenticated;
grant execute on function public.service_claim_customer_phone(uuid,text,bytea,text,smallint) to service_role;

-- Limited pre-consent metadata; do not relax RLS on financial tables just to
-- display a shop name on its invitation card.
create or replace function public.customer_pending_link_requests()
returns table(id uuid,status text,created_at timestamptz,business_name text,business_city text)
language sql stable security definer set search_path='' as $$
  select r.id,r.status::text,r.created_at,b.name,b.city
  from public.customer_link_requests r
  join public.customers c on c.id=r.target_customer_id
  join public.business_customers bc on bc.id=r.business_customer_id
  join public.businesses b on b.id=bc.business_id
  where c.user_id=auth.uid() and c.status='active' and r.status='pending'
    and r.expires_at>now() and not bc.is_archived and b.status='active'
  order by r.created_at desc
$$;
revoke all on function public.customer_pending_link_requests() from public,anon;
grant execute on function public.customer_pending_link_requests() to authenticated;
commit;

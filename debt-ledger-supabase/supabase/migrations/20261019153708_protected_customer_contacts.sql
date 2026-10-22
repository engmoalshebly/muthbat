begin;
alter table public.device_installations add column contact_session_id uuid references auth.sessions(id) on delete set null;
-- Clients cannot reactivate revoked devices or replace their session binding.
revoke insert,update on public.device_installations from authenticated;
grant update(device_name,app_version,last_seen_at) on public.device_installations to authenticated;

create function public.register_customer_contact_device(p_device_id uuid,p_platform text)
returns void language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_session uuid:=(auth.jwt()->>'session_id')::uuid;
begin
  if v_user is null or v_session is null or not exists(select 1 from auth.sessions where id=v_session and user_id=v_user) then
    raise exception 'Active session required' using errcode='42501';
  end if;
  if exists(select 1 from public.device_installations where user_id=v_user and device_id=p_device_id and revoked_at is not null) then
    raise exception 'Device revoked' using errcode='42501';
  end if;
  insert into public.device_installations(user_id,device_id,platform,contact_session_id)
  values(v_user,p_device_id,p_platform,v_session)
  on conflict(user_id,device_id) do update set contact_session_id=excluded.contact_session_id,last_seen_at=now()
  where public.device_installations.revoked_at is null;
end $$;
revoke all on function public.register_customer_contact_device(uuid,text) from public,anon;
grant execute on function public.register_customer_contact_device(uuid,text) to authenticated;

create function public.service_read_customer_contacts(p_user_id uuid,p_session_id uuid,p_device_id uuid,p_business_id uuid,p_customer_ids uuid[])
returns table(business_customer_id uuid,phone_ciphertext bytea,encryption_key_version smallint)
language plpgsql security definer set search_path='' as $$
begin
  if coalesce(cardinality(p_customer_ids),0) not between 1 and 100 then
    raise exception 'Invalid batch size' using errcode='22023';
  end if;
  if not exists(select 1 from public.device_installations d join auth.sessions s on s.id=d.contact_session_id and s.user_id=d.user_id
      where d.user_id=p_user_id and d.device_id=p_device_id and d.contact_session_id=p_session_id and d.revoked_at is null)
    or not exists(select 1 from public.business_members where business_id=p_business_id and user_id=p_user_id
      and status='active' and role in ('owner','admin','accountant','cashier')) then
    raise exception 'Not authorized to read contacts' using errcode='42501';
  end if;
  return query select b.id,c.phone_ciphertext,c.encryption_key_version
    from public.business_customers b join private.customer_contacts c on c.customer_id=b.customer_id
    where b.business_id=p_business_id and b.id=any(p_customer_ids) and not b.is_archived and c.phone_ciphertext is not null;
end $$;
revoke all on function public.service_read_customer_contacts(uuid,uuid,uuid,uuid,uuid[]) from public,anon,authenticated;
grant execute on function public.service_read_customer_contacts(uuid,uuid,uuid,uuid,uuid[]) to service_role;
commit;

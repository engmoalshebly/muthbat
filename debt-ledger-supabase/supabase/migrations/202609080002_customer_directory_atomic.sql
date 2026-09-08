begin;
-- Same lock namespace as phone adoption: concurrent directory requests cannot
-- create orphan identities or compete with a newly verified registration.
create or replace function public.service_resolve_customer_phone(
  p_phone_hash text,p_phone_ciphertext bytea,p_phone_last4 text,p_key_version smallint default 1
) returns table(customer_id uuid,user_id uuid,global_code text,phone_last4 text)
language plpgsql security definer set search_path='' as $$
declare v_customer public.customers%rowtype;
begin
  if p_phone_hash is null or length(p_phone_hash)<16 then raise exception 'invalid_phone_hash'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('customer-phone:'||p_phone_hash,0));
  select c.* into v_customer from public.customers c join private.customer_contacts cc on cc.customer_id=c.id
    where cc.phone_hash=p_phone_hash for update of c;
  if not found then
    insert into public.customers default values returning * into v_customer;
    perform private.service_upsert_customer_contact(v_customer.id,p_phone_hash,p_phone_ciphertext,p_phone_last4,null,p_key_version);
  elsif v_customer.status<>'active' then
    raise exception 'phone_identity_requires_review' using errcode='23505';
  end if;
  return query select v_customer.id,v_customer.user_id,v_customer.global_code::text,cc.phone_last4::text
    from private.customer_contacts cc where cc.customer_id=v_customer.id;
end;
$$;
revoke all on function public.service_resolve_customer_phone(text,bytea,text,smallint) from public,anon,authenticated;
grant execute on function public.service_resolve_customer_phone(text,bytea,text,smallint) to service_role;
commit;

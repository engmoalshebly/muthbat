-- Read-only; fail explicitly if this application build's RPC contract is absent.
do $$
declare signature text; fn regprocedure;
begin
  foreach signature in array array[
    'public.begin_customer_read_snapshot(text,uuid,text)',
    'public.read_customer_read_snapshot(uuid,bigint,integer)',
    'public.release_customer_read_snapshot(uuid)',
    'public.create_business_idempotent(uuid,jsonb)',
    'public.complete_customer_directory(uuid)',
    'public.service_prepare_customer_directory(uuid,uuid,jsonb,jsonb)',
    'public.register_customer_contact_device(uuid,text)',
    'public.service_read_customer_contacts(uuid,uuid,uuid,uuid,uuid[])',
    'public.begin_merchant_sync_snapshot(uuid,timestamptz,uuid[],uuid,uuid)',
    'public.read_merchant_sync_snapshot(uuid,bigint,integer)',
    'public.release_merchant_sync_snapshot(uuid)',
    'public.mutate_customer_profile(uuid,uuid,text,jsonb)',
    'public.add_dispute_message(uuid,text,uuid,text)',
    'public.client_sync_contract()'
  ] loop
    fn:=to_regprocedure(signature);
    if fn is null then raise exception 'Missing application RPC: %',signature; end if;
    if has_function_privilege('anon',fn,'EXECUTE') then raise exception 'Unexpected anonymous access: %',signature; end if;
  end loop;
  if not has_function_privilege('authenticated','public.begin_merchant_sync_snapshot(uuid,timestamptz,uuid[],uuid,uuid)','EXECUTE') then
    raise exception 'Missing snapshot caller permission';
  end if;
  if has_function_privilege('authenticated','public.service_read_customer_contacts(uuid,uuid,uuid,uuid,uuid[])','EXECUTE') then
    raise exception 'Private contact RPC exposed to application role';
  end if;
  if not has_function_privilege('authenticated','public.add_dispute_message(uuid,text,uuid,text)','EXECUTE') then
    raise exception 'Missing dispute reply caller permission';
  end if;
  if not has_column_privilege('authenticated','public.businesses','country_code','UPDATE')
     or has_column_privilege('authenticated','public.businesses','updated_at','UPDATE')
     or has_column_privilege('authenticated','public.businesses','owner_user_id','UPDATE') then
    raise exception 'Invalid business profile column grants';
  end if;
  if public.client_sync_contract()->>'version'<>'20261022-profile-disputes-v1' then
    raise exception 'Client sync contract mismatch';
  end if;
end $$;
select 'Account RPC contract verified; live device testing remains required.' as result;

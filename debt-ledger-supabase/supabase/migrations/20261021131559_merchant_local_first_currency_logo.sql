begin;

create table private.merchant_setting_receipts (
  user_id uuid not null references auth.users(id),
  request_id uuid not null,
  command_type text not null check (command_type in ('currencies','logo')),
  payload jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key (user_id, request_id)
);
alter table private.merchant_setting_receipts enable row level security;
revoke all on private.merchant_setting_receipts from public, anon, authenticated, service_role;

create function private.guard_merchant_currencies()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' or
     new.currency_code is distinct from old.currency_code or
     new.additional_currencies is distinct from old.additional_currencies then
    if new.currency_code not in ('YER','SAR','USD') or exists (
      select 1 from unnest(coalesce(new.additional_currencies, '{}'::text[])) c
      where c not in ('YER','SAR','USD')
    ) then
      raise exception 'Only YER, SAR and USD are available for new business settings'
        using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
create trigger guard_merchant_currencies
before insert or update on public.businesses
for each row execute function private.guard_merchant_currencies();

create function private.guard_new_ledger_currency()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.currency_code not in ('YER','SAR','USD')
     and new.entry_type <> 'reversal' then
    raise exception 'Only YER, SAR and USD are available for new entries'
      using errcode = '22023';
  end if;
  return new;
end $$;
create trigger guard_new_ledger_currency
before insert on public.ledger_entries
for each row execute function private.guard_new_ledger_currency();

create function public.update_business_currencies_idempotent(
  p_business_id uuid, p_additional_currencies text[], p_request_id uuid
) returns text[] language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_payload jsonb;
  v_receipt private.merchant_setting_receipts%rowtype;
  v_result text[];
begin
  if v_user is null or p_request_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  select coalesce(array_agg(distinct upper(trim(c)) order by upper(trim(c))), '{}')
    into v_result from unnest(coalesce(p_additional_currencies, '{}'::text[])) c;
  if exists (select 1 from unnest(v_result) c where c not in ('YER','SAR','USD')) then
    raise exception 'Unsupported currency' using errcode = '22023';
  end if;
  v_payload := jsonb_build_object('business_id',p_business_id,'additional',to_jsonb(v_result));
  perform pg_advisory_xact_lock(hashtextextended(v_user::text || p_request_id::text, 0));
  select * into v_receipt from private.merchant_setting_receipts
    where user_id = v_user and request_id = p_request_id;
  if found then
    if v_receipt.command_type <> 'currencies' or v_receipt.payload is distinct from v_payload then
      raise exception 'Request payload cannot change' using errcode = '22023';
    end if;
    select array_agg(item.value) into v_result
      from jsonb_array_elements_text(v_receipt.result->'additional') as item(value);
    return coalesce(v_result, '{}'::text[]);
  end if;
  v_result := public.update_business_currencies(p_business_id, v_result);
  insert into private.merchant_setting_receipts(user_id,request_id,command_type,payload,result)
    values(v_user,p_request_id,'currencies',v_payload,jsonb_build_object('additional',to_jsonb(v_result)));
  return v_result;
end $$;
revoke all on function public.update_business_currencies_idempotent(uuid,text[],uuid) from public, anon;
grant execute on function public.update_business_currencies_idempotent(uuid,text[],uuid) to authenticated;

create function public.set_business_logo_idempotent(
  p_business_id uuid, p_object_path text, p_request_id uuid
) returns text language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_payload jsonb := jsonb_build_object('business_id',p_business_id,'path',p_object_path);
  v_receipt private.merchant_setting_receipts%rowtype;
begin
  if v_user is null or p_request_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user::text || p_request_id::text, 0));
  select * into v_receipt from private.merchant_setting_receipts
    where user_id = v_user and request_id = p_request_id;
  if found then
    if v_receipt.command_type <> 'logo' or v_receipt.payload is distinct from v_payload then
      raise exception 'Request payload cannot change' using errcode = '22023';
    end if;
    return v_receipt.result->>'path';
  end if;
  if not private.is_business_member(p_business_id,array['owner','admin']::public.business_role[]) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_object_path !~ ('^' || p_business_id::text || '/logo/' || p_request_id::text || '\.(jpg|jpeg|png|webp)$') then
    raise exception 'Invalid logo path' using errcode = '22023';
  end if;
  if not exists (select 1 from storage.objects where bucket_id='business-assets' and name=p_object_path) then
    raise exception 'Logo upload not found' using errcode = 'P0002';
  end if;
  update public.businesses set logo_path=p_object_path,updated_at=now()
    where id=p_business_id and status='active';
  if not found then raise exception 'Business not found' using errcode='P0002'; end if;
  insert into private.merchant_setting_receipts(user_id,request_id,command_type,payload,result)
    values(v_user,p_request_id,'logo',v_payload,jsonb_build_object('path',p_object_path));
  return p_object_path;
end $$;
revoke all on function public.set_business_logo_idempotent(uuid,text,uuid) from public, anon;
grant execute on function public.set_business_logo_idempotent(uuid,text,uuid) to authenticated;

commit;

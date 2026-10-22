begin;
create table private.merchant_sync_snapshots(
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id),
  business_id uuid not null references public.businesses(id), device_id uuid not null, created_at timestamptz not null default now()
);
create table private.merchant_sync_devices(
  user_id uuid not null references auth.users(id),device_id uuid not null,business_id uuid not null references public.businesses(id),
  last_snapshot_id uuid, primary key(user_id,device_id,business_id)
);
create table private.merchant_sync_entry_acks(
  user_id uuid not null references auth.users(id),device_id uuid not null,business_id uuid not null references public.businesses(id),
  entry_id uuid not null references public.ledger_entries(id), state_signature text, entry_signature text,
  primary key(user_id,device_id,business_id,entry_id)
);
create table private.merchant_sync_snapshot_items(
  snapshot_id uuid not null references private.merchant_sync_snapshots(id) on delete cascade,
  ordinal bigint not null, kind text not null, payload jsonb not null, primary key(snapshot_id,ordinal)
);
create index merchant_sync_snapshots_user_expiry on private.merchant_sync_snapshots(user_id,created_at);
create index merchant_sync_snapshots_expiry on private.merchant_sync_snapshots(created_at);
create function private.purge_expired_merchant_sync_snapshots()
returns void language sql set search_path='' as $$
  delete from private.merchant_sync_snapshots where id in (
    select id from private.merchant_sync_snapshots where created_at<now()-interval '1 hour' order by created_at limit 1000
  );
$$;
revoke all on function private.purge_expired_merchant_sync_snapshots() from public,anon,authenticated,service_role;
do $$ begin
  if not exists(select 1 from cron.job where jobname='merchant-sync-snapshot-expiry') then
    perform cron.schedule('merchant-sync-snapshot-expiry','*/15 * * * *','select private.purge_expired_merchant_sync_snapshots();');
  end if;
end $$;
alter table private.merchant_sync_snapshots enable row level security;
alter table private.merchant_sync_snapshot_items enable row level security;
alter table private.merchant_sync_devices enable row level security;
alter table private.merchant_sync_entry_acks enable row level security;
revoke all on private.merchant_sync_snapshots,private.merchant_sync_snapshot_items from public,anon,authenticated,service_role;
revoke all on private.merchant_sync_devices,private.merchant_sync_entry_acks from public,anon,authenticated,service_role;

create function public.begin_merchant_sync_snapshot(p_business_id uuid,p_cursor timestamptz default null,p_pending_requests uuid[] default '{}',p_device_id uuid default null,p_previous_snapshot_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_count bigint; v_previous uuid;
begin
  if auth.uid() is null or not private.is_business_member(p_business_id,null) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  if cardinality(p_pending_requests)>10000 then raise exception 'Too many pending requests' using errcode='22023'; end if;
  if p_device_id is null then raise exception 'Device required' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_device_id::text||p_business_id::text,0));
  select last_snapshot_id into v_previous from private.merchant_sync_devices
    where user_id=auth.uid() and device_id=p_device_id and business_id=p_business_id;
  if v_previous is distinct from p_previous_snapshot_id or p_previous_snapshot_id is null then
    -- An older/restored local cache cannot inherit newer delivery acknowledgments.
    delete from private.merchant_sync_entry_acks where user_id=auth.uid() and device_id=p_device_id and business_id=p_business_id;
  end if;
  -- Expired snapshots are disposable copies, scoped to this authenticated user.
  delete from private.merchant_sync_snapshots where user_id=auth.uid() and created_at<now()-interval '1 hour';
  insert into private.merchant_sync_snapshots(user_id,business_id,device_id) values(auth.uid(),p_business_id,p_device_id) returning id into v_id;
  -- One statement means every entity and balance uses the SAME MVCC snapshot.
  insert into private.merchant_sync_snapshot_items(snapshot_id,ordinal,kind,payload)
  with entry_projection as (
    select e.id,e.client_request_id,to_jsonb(e)||jsonb_build_object(
      'confirmation_status',s.confirmation_status,'dispute_status',s.dispute_status,
      'is_reversed',s.is_reversed,'reversal_entry_id',s.reversal_entry_id,'local_category_label',labels.label) payload
    from public.ledger_entries e join public.ledger_entry_state s on s.entry_id=e.id
    left join public.local_import_entry_categories labels on labels.entry_id=e.id
    where e.business_id=p_business_id
  )
  select v_id,row_number() over(order by kind,entity_id),kind,payload from (
    select 'customer'::text kind,b.id::text entity_id,to_jsonb(b)||jsonb_build_object(
      'current_balance',coalesce(v.current_balance,0),'overdue_balance',coalesce(v.gross_overdue_debits,0)) payload
      from public.business_customers b join public.businesses business on business.id=b.business_id
      left join public.business_customer_balances v on v.business_customer_id=b.id and v.currency_code=business.currency_code
      where b.business_id=p_business_id
    union all
    select 'entry',e.id::text,e.payload from entry_projection e
      where (
        not exists(select 1 from private.merchant_sync_entry_acks a where a.user_id=auth.uid()
          and a.device_id=p_device_id and a.business_id=p_business_id and a.entry_id=e.id
          and a.entry_signature=md5(e.payload::text))
        or e.client_request_id=any(p_pending_requests))
    union all
    select 'state',s.entry_id::text,to_jsonb(s) from public.ledger_entry_state s
      join public.ledger_entries e on e.id=s.entry_id where e.business_id=p_business_id
      and not exists(select 1 from private.merchant_sync_entry_acks a where a.user_id=auth.uid()
        and a.device_id=p_device_id and a.business_id=p_business_id and a.entry_id=s.entry_id
        and a.state_signature=md5(to_jsonb(s)::text))
    union all
    select 'balance',b.business_customer_id::text||':'||b.currency_code,to_jsonb(b)
      from public.customer_currency_balances b where b.business_id=p_business_id
  ) entities;
  get diagnostics v_count=row_count;
  return jsonb_build_object('snapshot_id',v_id,'item_count',v_count);
end $$;

create function public.read_merchant_sync_snapshot(p_snapshot_id uuid,p_after bigint default 0,p_limit integer default 500)
returns table(ordinal bigint,kind text,payload jsonb) language plpgsql security definer set search_path='' as $$
declare v_business uuid;
begin
  select business_id into v_business from private.merchant_sync_snapshots
    where id=p_snapshot_id and user_id=auth.uid() and created_at>now()-interval '1 hour';
  if v_business is null or not private.is_business_member(v_business,null) then
    raise exception 'Snapshot unavailable' using errcode='42501';
  end if;
  if p_limit not between 1 and 500 or p_after<0 then raise exception 'Invalid page' using errcode='22023'; end if;
  return query select i.ordinal,i.kind,i.payload from private.merchant_sync_snapshot_items i
    where i.snapshot_id=p_snapshot_id and i.ordinal>p_after order by i.ordinal limit p_limit;
end $$;
revoke all on function public.begin_merchant_sync_snapshot(uuid,timestamptz,uuid[],uuid,uuid) from public,anon;
revoke all on function public.read_merchant_sync_snapshot(uuid,bigint,integer) from public,anon;
grant execute on function public.begin_merchant_sync_snapshot(uuid,timestamptz,uuid[],uuid,uuid), public.read_merchant_sync_snapshot(uuid,bigint,integer) to authenticated;
create function public.release_merchant_sync_snapshot(p_snapshot_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_snapshot private.merchant_sync_snapshots%rowtype;
begin
  select * into v_snapshot from private.merchant_sync_snapshots where id=p_snapshot_id and user_id=auth.uid();
  if not found then return; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||v_snapshot.device_id::text||v_snapshot.business_id::text,0));
  insert into private.merchant_sync_entry_acks(user_id,device_id,business_id,entry_id,entry_signature)
    select auth.uid(),v_snapshot.device_id,v_snapshot.business_id,(i.payload->>'id')::uuid,md5(i.payload::text)
    from private.merchant_sync_snapshot_items i where i.snapshot_id=p_snapshot_id and i.kind='entry'
    on conflict(user_id,device_id,business_id,entry_id) do update set entry_signature=excluded.entry_signature;
  update private.merchant_sync_entry_acks a set state_signature=md5(i.payload::text)
    from private.merchant_sync_snapshot_items i where i.snapshot_id=p_snapshot_id and i.kind='state'
    and a.user_id=auth.uid() and a.device_id=v_snapshot.device_id and a.business_id=v_snapshot.business_id
    and a.entry_id=(i.payload->>'entry_id')::uuid;
  insert into private.merchant_sync_devices values(auth.uid(),v_snapshot.device_id,v_snapshot.business_id,p_snapshot_id)
    on conflict(user_id,device_id,business_id) do update set last_snapshot_id=excluded.last_snapshot_id;
  delete from private.merchant_sync_snapshots where id=p_snapshot_id and user_id=auth.uid();
end;
$$;
revoke all on function public.release_merchant_sync_snapshot(uuid) from public,anon;
grant execute on function public.release_merchant_sync_snapshot(uuid) to authenticated;

create table private.customer_profile_command_receipts(
  user_id uuid not null references auth.users(id),request_id uuid not null,payload jsonb not null,result jsonb not null,
  primary key(user_id,request_id)
);
alter table private.customer_profile_command_receipts enable row level security;
revoke all on private.customer_profile_command_receipts from public,anon,authenticated,service_role;
create function public.mutate_customer_profile(p_request_id uuid,p_business_customer_id uuid,p_action text,p_profile jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_payload jsonb; v_receipt private.customer_profile_command_receipts%rowtype; v_result jsonb; v_business uuid;
begin
  select business_id into v_business from public.business_customers where id=p_business_customer_id;
  if auth.uid() is null or p_request_id is null or v_business is null or not private.is_business_member(v_business,array['owner']::public.business_role[]) then
    raise exception 'Owner permission required' using errcode='42501';
  end if;
  v_payload:=jsonb_build_object('customer',p_business_customer_id,'action',p_action,'profile',p_profile);
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_id::text,0));
  select * into v_receipt from private.customer_profile_command_receipts where user_id=auth.uid() and request_id=p_request_id;
  if found then
    if v_receipt.payload is distinct from v_payload then raise exception 'Request payload cannot change' using errcode='22023'; end if;
    return v_receipt.result;
  end if;
  if p_action='update' then
    v_result:=public.update_business_customer_profile(p_business_customer_id,p_profile->>'display_name',p_profile->>'note',
      (p_profile->>'credit_limit')::numeric,(p_profile->>'default_due_days')::smallint);
  elsif p_action='archive' then v_result:=public.archive_business_customer(p_business_customer_id);
  else raise exception 'Invalid action' using errcode='22023'; end if;
  insert into private.customer_profile_command_receipts values(auth.uid(),p_request_id,v_payload,v_result);
  return v_result;
end $$;
revoke all on function public.mutate_customer_profile(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.mutate_customer_profile(uuid,uuid,text,jsonb) to authenticated;
commit;

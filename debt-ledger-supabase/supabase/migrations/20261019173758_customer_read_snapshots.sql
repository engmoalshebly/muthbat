begin;
create table private.customer_read_snapshots (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
create index customer_read_snapshot_expiry on private.customer_read_snapshots(created_at);
create index customer_read_snapshot_owner on private.customer_read_snapshots(user_id,created_at);
create table private.customer_read_snapshot_items (
 snapshot_id uuid not null references private.customer_read_snapshots(id) on delete cascade,
 ordinal bigint not null, kind text not null, payload jsonb not null, primary key(snapshot_id,ordinal)
);
alter table private.customer_read_snapshots enable row level security;
alter table private.customer_read_snapshot_items enable row level security;
revoke all on private.customer_read_snapshots,private.customer_read_snapshot_items from public,anon,authenticated,service_role;

create function public.begin_customer_read_snapshot(p_scope text default 'home',p_business_customer_id uuid default null,p_currency_code text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_count bigint;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status='active') then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 if p_scope not in ('home','ledger') or p_scope is null then raise exception 'Invalid scope' using errcode='22023'; end if;
 if p_scope='ledger' and (p_business_customer_id is null or p_currency_code is null or not exists(
  select 1 from public.business_customers bc join public.customers c on c.id=bc.customer_id join public.businesses b on b.id=bc.business_id
  where bc.id=p_business_customer_id and c.user_id=auth.uid() and c.status='active' and bc.link_status='linked' and not bc.is_archived and b.status='active')) then
  raise exception 'Account unavailable' using errcode='42501';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('customer-read:'||auth.uid()::text,0));
 delete from private.customer_read_snapshots where user_id=auth.uid() and created_at<now()-interval '1 hour';
 if (select count(*) from private.customer_read_snapshots where user_id=auth.uid())>=8 then
  raise exception 'Too many active snapshots' using errcode='54000';
 end if;
 insert into private.customer_read_snapshots(user_id) values(auth.uid()) returning id into v_id;
 -- All home sections / the entire exported ledger share one MVCC statement snapshot.
 insert into private.customer_read_snapshot_items(snapshot_id,ordinal,kind,payload)
 with identity as materialized (select id from public.customers where user_id=auth.uid() and status='active'),
 allowed as materialized (
  select bc.id from public.business_customers bc join identity c on c.id=bc.customer_id
  join public.businesses b on b.id=bc.business_id
  where bc.link_status='linked' and not bc.is_archived and b.status='active'
 ), entities as (
  select 'metadata'::text kind,''::text key,jsonb_build_object('customer_id',(select id from identity),'updated_at',statement_timestamp()) payload
  union all
  select 'summary',s.business_customer_id::text||':'||s.currency_code,to_jsonb(s)
  from public.customer_business_summary s join allowed a on a.id=s.business_customer_id
  where p_scope='home' or (s.business_customer_id=p_business_customer_id and s.currency_code=p_currency_code)
  union all
  select 'request',r.id::text,to_jsonb(r) from public.customer_pending_link_requests() r where p_scope='home'
  union all
  select 'entry',e.occurred_at::text||':'||e.id::text,to_jsonb(e)
  from public.ledger_timeline e join allowed a on a.id=e.business_customer_id
  where (p_scope='home' and e.confirmation_status='pending' and not e.is_reversed and e.dispute_status='none')
     or (p_scope='ledger' and e.business_customer_id=p_business_customer_id and e.currency_code=p_currency_code)
 ) select v_id,row_number() over(order by kind,key),kind,payload from entities;
 get diagnostics v_count=row_count;
 return jsonb_build_object('snapshot_id',v_id,'item_count',v_count);
end $$;

create function public.read_customer_read_snapshot(p_snapshot_id uuid,p_after bigint default 0,p_limit integer default 250)
returns table(ordinal bigint,kind text,payload jsonb) language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and status='active')
  or not exists(select 1 from private.customer_read_snapshots where id=p_snapshot_id and user_id=auth.uid() and created_at>now()-interval '1 hour') then
  raise exception 'Snapshot unavailable' using errcode='42501';
 end if;
 if p_after<0 or p_limit not between 1 and 250 then raise exception 'Invalid page' using errcode='22023'; end if;
 -- Recheck current consent: a frozen copy must never bypass a revoked link.
 if exists(select 1 from private.customer_read_snapshot_items i where i.snapshot_id=p_snapshot_id
   and i.kind in ('summary','entry') and not exists (
    select 1 from public.business_customers bc join public.customers c on c.id=bc.customer_id join public.businesses b on b.id=bc.business_id
    where bc.id=(i.payload->>'business_customer_id')::uuid and c.user_id=auth.uid() and c.status='active'
      and bc.link_status='linked' and not bc.is_archived and b.status='active')) then
  raise exception 'Account access changed; refresh snapshot' using errcode='42501';
 end if;
 return query select i.ordinal,i.kind,i.payload from private.customer_read_snapshot_items i
  where i.snapshot_id=p_snapshot_id and i.ordinal>p_after order by i.ordinal limit p_limit;
end $$;
create function public.release_customer_read_snapshot(p_snapshot_id uuid)
returns void language sql security definer set search_path='' as $$
 delete from private.customer_read_snapshots where id=p_snapshot_id and user_id=auth.uid();
$$;
revoke all on function public.begin_customer_read_snapshot(text,uuid,text),public.read_customer_read_snapshot(uuid,bigint,integer),public.release_customer_read_snapshot(uuid) from public,anon;
grant execute on function public.begin_customer_read_snapshot(text,uuid,text),public.read_customer_read_snapshot(uuid,bigint,integer),public.release_customer_read_snapshot(uuid) to authenticated;
create function private.purge_expired_customer_read_snapshots() returns void language sql set search_path='' as $$
 delete from private.customer_read_snapshots where id in (select id from private.customer_read_snapshots where created_at<now()-interval '1 hour' order by created_at limit 1000);
$$;
revoke all on function private.purge_expired_customer_read_snapshots() from public,anon,authenticated,service_role;
select cron.schedule('customer-read-snapshot-expiry','*/15 * * * *','select private.purge_expired_customer_read_snapshots();');
commit;

begin;
create table if not exists private.customer_action_receipts (
  user_id uuid not null references auth.users(id),
  request_id uuid not null,
  payload jsonb not null,
  completed_at timestamptz not null default now(),
  primary key(user_id,request_id)
);
revoke all on private.customer_action_receipts from public,anon,authenticated;

create or replace function public.submit_customer_action(p_request_id uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_existing jsonb; v_target uuid; v_kind text;
begin
  if v_user is null or not exists(select 1 from public.profiles where id=v_user and status='active') then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  if p_request_id is null or p_payload is null then raise exception 'Invalid action'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('customer-action:'||v_user::text||':'||p_request_id::text,0));
  select payload into v_existing from private.customer_action_receipts where user_id=v_user and request_id=p_request_id;
  if found then
    if v_existing<>p_payload then raise exception 'Request payload mismatch' using errcode='22023'; end if;
    return jsonb_build_object('completed',true,'replayed',true);
  end if;
  v_kind:=p_payload->>'kind'; v_target:=(p_payload->>'target_id')::uuid;
  if v_kind in ('confirm','dispute') then
    -- Consent and current ownership are rechecked at execution, not when queued.
    if not exists(select 1 from public.ledger_entries le
      join public.customers c on c.id=le.customer_id
      join public.business_customers bc on bc.id=le.business_customer_id
      join public.businesses b on b.id=bc.business_id
      join public.ledger_entry_state s on s.entry_id=le.id
      where le.id=v_target and c.user_id=v_user and c.status='active'
        and bc.link_status='linked' and not bc.is_archived and b.status='active' and not s.is_reversed) then
      raise exception 'Not authorized or entry unavailable' using errcode='42501';
    end if;
    if v_kind='confirm' then
      perform public.confirm_ledger_entry(v_target);
    else
      if length(trim(coalesce(p_payload->>'description','')))<1 or length(p_payload->>'description')>4000 then raise exception 'Invalid description'; end if;
      perform public.open_dispute(v_target,(p_payload->>'reason')::public.dispute_reason,p_payload->>'description');
    end if;
  elsif v_kind='link' then
    if jsonb_typeof(p_payload->'accept')<>'boolean' or not (p_payload ? 'accept') then raise exception 'Invalid consent'; end if;
    perform public.respond_link_request(v_target,(p_payload->>'accept')::boolean);
  else raise exception 'Unknown customer action';
  end if;
  insert into private.customer_action_receipts(user_id,request_id,payload) values(v_user,p_request_id,p_payload);
  return jsonb_build_object('completed',true,'replayed',false);
end;
$$;
revoke all on function public.submit_customer_action(uuid,jsonb) from public,anon;
grant execute on function public.submit_customer_action(uuid,jsonb) to authenticated;
commit;

-- Debt Ledger MVP - Member invitations and immutable statement snapshots
begin;

create type public.member_invite_status as enum ('pending','accepted','rejected','expired','cancelled');

create table public.business_member_invites (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  target_user_id uuid not null references auth.users(id) on delete restrict,
  role public.business_role not null check (role <> 'owner'),
  status public.member_invite_status not null default 'pending',
  invited_by_user_id uuid not null references auth.users(id) on delete restrict,
  responded_at timestamptz,
  expires_at timestamptz not null default (now() + interval '7 days'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index uq_pending_business_member_invite
  on public.business_member_invites(business_id,target_user_id)
  where status='pending';
create index idx_member_invites_target_status
  on public.business_member_invites(target_user_id,status,created_at desc);

alter table public.business_member_invites enable row level security;
revoke all on public.business_member_invites from anon,authenticated;
grant select on public.business_member_invites to authenticated;
create policy member_invites_select_allowed on public.business_member_invites for select to authenticated
using (target_user_id=(select auth.uid()) or private.is_business_member(business_id,array['owner','admin']::public.business_role[]));
create trigger trg_business_member_invites_updated_at before update on public.business_member_invites
for each row execute function private.set_updated_at();

create or replace function private.command_invite_business_member(
  p_business_id uuid,p_target_user_id uuid,p_role public.business_role,p_expires_at timestamptz default (now()+interval '7 days')
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if p_role='owner' then raise exception 'Owner role cannot be invited'; end if;
  if p_target_user_id=(select auth.uid()) then raise exception 'Cannot invite yourself'; end if;
  if p_expires_at<=now() then raise exception 'Invite expiry must be in the future'; end if;
  if not private.is_business_member(p_business_id,array['owner','admin']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  if exists(select 1 from public.business_members where business_id=p_business_id and user_id=p_target_user_id and status='active') then
    raise exception 'User is already an active member';
  end if;
  update public.business_member_invites set status='cancelled',updated_at=now()
  where business_id=p_business_id and target_user_id=p_target_user_id and status='pending';
  insert into public.business_member_invites(business_id,target_user_id,role,invited_by_user_id,expires_at)
  values(p_business_id,p_target_user_id,p_role,(select auth.uid()),p_expires_at)
  returning id into v_id;
  perform private.enqueue_notification(p_target_user_id,'system','دعوة للانضمام إلى محل','لديك دعوة للانضمام إلى فريق محل.','business_member_invite',v_id,jsonb_build_object('business_id',p_business_id,'role',p_role));
  return v_id;
end;
$$;

create or replace function public.invite_business_member(
  p_business_id uuid,p_target_user_id uuid,p_role public.business_role,p_expires_at timestamptz default (now()+interval '7 days')
)
returns uuid language sql set search_path=''
as $$ select private.command_invite_business_member(p_business_id,p_target_user_id,p_role,p_expires_at) $$;

create or replace function private.command_respond_business_member_invite(p_invite_id uuid,p_accept boolean)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_invite public.business_member_invites%rowtype; v_owner uuid;
begin
  select * into v_invite from public.business_member_invites where id=p_invite_id for update;
  if not found or v_invite.status<>'pending' or v_invite.expires_at<now() then raise exception 'Invalid or expired invitation'; end if;
  if v_invite.target_user_id<>(select auth.uid()) then raise exception 'Not authorized' using errcode='42501'; end if;
  update public.business_member_invites
  set status=case when p_accept then 'accepted'::public.member_invite_status else 'rejected'::public.member_invite_status end,
      responded_at=now(),updated_at=now()
  where id=p_invite_id;
  if p_accept then
    insert into public.business_members(business_id,user_id,role,status,invited_by_user_id)
    values(v_invite.business_id,v_invite.target_user_id,v_invite.role,'active',v_invite.invited_by_user_id)
    on conflict(business_id,user_id) do update set role=excluded.role,status='active',updated_at=now();
  end if;
  select owner_user_id into v_owner from public.businesses where id=v_invite.business_id;
  perform private.enqueue_notification(v_owner,'system',case when p_accept then 'تم قبول دعوة الموظف' else 'تم رفض دعوة الموظف' end,
    case when p_accept then 'قبل المستخدم دعوة الانضمام إلى المحل.' else 'رفض المستخدم دعوة الانضمام إلى المحل.' end,
    'business_member_invite',p_invite_id,'{}'::jsonb);
end;
$$;

create or replace function public.respond_business_member_invite(p_invite_id uuid,p_accept boolean)
returns void language sql set search_path=''
as $$ select private.command_respond_business_member_invite(p_invite_id,p_accept) $$;

create or replace function private.expire_business_member_invites()
returns integer
language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
  update public.business_member_invites set status='expired',updated_at=now()
  where status='pending' and expires_at<now();
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;

do $$
begin
  if not exists(select 1 from cron.job where jobname='expire-business-member-invites') then
    perform cron.schedule('expire-business-member-invites','*/15 * * * *','select private.expire_business_member_invites();');
  end if;
end $$;

create or replace function private.command_create_statement(
  p_scope public.statement_scope,
  p_business_customer_id uuid default null,
  p_period_from timestamptz default (now()-interval '30 days'),
  p_period_to timestamptz default now()
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_customer uuid;
  v_business uuid;
  v_currency varchar(3);
  v_currency_count integer;
  v_opening numeric(20,4);
  v_debits numeric(20,4);
  v_credits numeric(20,4);
  v_statement uuid;
  v_code text;
begin
  if p_period_to<=p_period_from then raise exception 'Statement period end must be after its start'; end if;
  if p_scope='business_customer' then
    if p_business_customer_id is null then raise exception 'Business customer is required'; end if;
    select customer_id,business_id into v_customer,v_business from public.business_customers where id=p_business_customer_id;
    if not found then raise exception 'Business customer not found'; end if;
    if not (private.is_business_member(v_business,array['owner','admin','accountant']::public.business_role[]) or private.can_customer_access_business_customer(p_business_customer_id)) then
      raise exception 'Not authorized' using errcode='42501';
    end if;
    select currency_code into v_currency from public.businesses where id=v_business;
  else
    if p_business_customer_id is not null then raise exception 'Consolidated statements cannot include a business customer'; end if;
    v_customer:=private.current_customer_id();
    if v_customer is null then raise exception 'Only a registered customer can create a consolidated statement' using errcode='42501'; end if;
    select count(distinct currency_code),min(currency_code) into v_currency_count,v_currency
    from public.ledger_entries where customer_id=v_customer;
    if v_currency_count>1 then raise exception 'Consolidated statements require a single currency'; end if;
  end if;
  select coalesce(sum(case when direction='debit' then amount else -amount end),0)::numeric(20,4)
  into v_opening from public.ledger_entries
  where customer_id=v_customer and (p_scope='customer_consolidated' or business_customer_id=p_business_customer_id) and occurred_at<p_period_from;
  select coalesce(sum(case when direction='debit' then amount else 0 end),0)::numeric(20,4),
         coalesce(sum(case when direction='credit' then amount else 0 end),0)::numeric(20,4)
  into v_debits,v_credits from public.ledger_entries
  where customer_id=v_customer and (p_scope='customer_consolidated' or business_customer_id=p_business_customer_id)
    and occurred_at>=p_period_from and occurred_at<p_period_to;
  loop
    v_code:='ST-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    begin
      insert into public.statements(scope,business_id,business_customer_id,customer_id,period_from,period_to,currency_code,opening_balance,total_debits,total_credits,closing_balance,verification_code,generated_by_user_id)
      values(p_scope,v_business,p_business_customer_id,v_customer,p_period_from,p_period_to,v_currency,v_opening,v_debits,v_credits,v_opening+v_debits-v_credits,v_code,(select auth.uid()))
      returning id into v_statement;
      exit;
    exception when unique_violation then
      -- Retry only the extremely unlikely verification-code collision.
    end;
  end loop;
  insert into public.statement_items(statement_id,entry_id,item_order,occurred_at,description_snapshot,debit_amount,credit_amount,running_balance,confirmation_status)
  select v_statement,le.id,row_number() over(order by le.occurred_at,le.id),le.occurred_at,le.description,
    case when le.direction='debit' then le.amount else 0 end,
    case when le.direction='credit' then le.amount else 0 end,
    v_opening+sum(case when le.direction='debit' then le.amount else -le.amount end) over(order by le.occurred_at,le.id rows unbounded preceding),
    les.confirmation_status
  from public.ledger_entries le join public.ledger_entry_state les on les.entry_id=le.id
  where le.customer_id=v_customer and (p_scope='customer_consolidated' or le.business_customer_id=p_business_customer_id)
    and le.occurred_at>=p_period_from and le.occurred_at<p_period_to
  order by le.occurred_at,le.id;
  return v_statement;
end;
$$;

create or replace function public.create_statement(
  p_scope public.statement_scope,p_business_customer_id uuid default null,p_period_from timestamptz default (now()-interval '30 days'),p_period_to timestamptz default now()
)
returns uuid language sql set search_path=''
as $$ select private.command_create_statement(p_scope,p_business_customer_id,p_period_from,p_period_to) $$;

create or replace function private.service_attach_statement_document(p_statement_id uuid,p_object_path text,p_sha256_hex text)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  if p_object_path is null or char_length(trim(p_object_path))=0 then raise exception 'Statement object path is required'; end if;
  if p_sha256_hex is not null and p_sha256_hex !~ '^[0-9a-f]{64}$' then raise exception 'Invalid statement hash'; end if;
  update public.statements set pdf_object_path=trim(p_object_path),snapshot_sha256_hex=p_sha256_hex where id=p_statement_id;
  if not found then raise exception 'Statement not found'; end if;
end;
$$;

create or replace function public.service_attach_statement_document(p_statement_id uuid,p_object_path text,p_sha256_hex text)
returns void language sql set search_path=''
as $$ select private.service_attach_statement_document(p_statement_id,p_object_path,p_sha256_hex) $$;

grant execute on function public.invite_business_member(uuid,uuid,public.business_role,timestamptz) to authenticated;
grant execute on function public.respond_business_member_invite(uuid,boolean) to authenticated;
grant execute on function public.create_statement(public.statement_scope,uuid,timestamptz,timestamptz) to authenticated;
grant usage on schema private to authenticated;
grant execute on function private.command_invite_business_member(uuid,uuid,public.business_role,timestamptz) to authenticated;
grant execute on function private.command_respond_business_member_invite(uuid,boolean) to authenticated;
grant execute on function private.command_create_statement(public.statement_scope,uuid,timestamptz,timestamptz) to authenticated;
revoke all on function private.service_attach_statement_document(uuid,text,text) from public,anon,authenticated;
revoke all on function public.service_attach_statement_document(uuid,text,text) from public,anon,authenticated;
grant execute on function private.service_attach_statement_document(uuid,text,text) to service_role;
grant execute on function public.service_attach_statement_document(uuid,text,text) to service_role;

commit;

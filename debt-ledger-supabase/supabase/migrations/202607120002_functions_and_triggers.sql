-- Debt Ledger MVP - Command functions, invariants and projections
begin;

-- ---------- Authorization helpers ----------
create or replace function private.current_customer_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id from public.customers c
  where c.user_id = (select auth.uid()) and c.status = 'active'
  limit 1
$$;

create or replace function private.is_business_member(
  p_business_id uuid,
  p_roles public.business_role[] default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null and exists (
    select 1
    from public.business_members bm
    where bm.business_id = p_business_id
      and bm.user_id = (select auth.uid())
      and bm.status = 'active'
      and (p_roles is null or bm.role = any(p_roles))
  )
$$;

create or replace function private.is_customer_owner(p_customer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.customers c
    where c.id = p_customer_id
      and c.user_id = (select auth.uid())
      and c.status = 'active'
  )
$$;

create or replace function private.can_access_business_customer(p_business_customer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.business_customers bc
    where bc.id = p_business_customer_id
      and (
        private.is_business_member(bc.business_id, null)
        or (bc.link_status = 'linked' and private.is_customer_owner(bc.customer_id))
      )
  )
$$;

create or replace function private.can_access_ledger_entry(p_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.ledger_entries le
    where le.id = p_entry_id
      and (
        private.is_business_member(le.business_id, null)
        or private.is_customer_owner(le.customer_id)
      )
  )
$$;

-- ---------- Notification helper ----------
create or replace function private.enqueue_notification(
  p_user_id uuid,
  p_type public.notification_type,
  p_title text,
  p_body text,
  p_entity_type text default null,
  p_entity_id uuid default null,
  p_data jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  insert into public.notifications(user_id, type, title, body, entity_type, entity_id, data)
  values (p_user_id, p_type, p_title, p_body, p_entity_type, p_entity_id, coalesce(p_data, '{}'::jsonb))
  returning id into v_id;

  insert into private.notification_outbox(notification_id) values (v_id);
  return v_id;
end;
$$;

-- ---------- New auth user bootstrap ----------
create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_name text;
begin
  v_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    'مستخدم جديد'
  );

  insert into public.profiles(id, display_name)
  values (new.id, v_name)
  on conflict (id) do nothing;

  insert into public.customers(user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function private.handle_new_auth_user();

-- ---------- Business commands ----------
create or replace function private.command_create_business(
  p_name text,
  p_business_type text,
  p_currency_code varchar,
  p_country_code varchar default 'YE',
  p_city text default null,
  p_address text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_user uuid := (select auth.uid()); v_business uuid;
begin
  if v_user is null then raise exception 'Authentication required' using errcode='28000'; end if;

  insert into public.businesses(owner_user_id, name, business_type, currency_code, country_code, city, address)
  values (v_user, trim(p_name), trim(p_business_type), upper(p_currency_code), upper(p_country_code), p_city, p_address)
  returning id into v_business;

  insert into public.business_members(business_id, user_id, role, status)
  values (v_business, v_user, 'owner', 'active');

  return v_business;
end;
$$;

create or replace function public.create_business(
  p_name text,
  p_business_type text,
  p_currency_code varchar,
  p_country_code varchar default 'YE',
  p_city text default null,
  p_address text default null
)
returns uuid
language sql
set search_path = ''
as $$ select private.command_create_business(p_name,p_business_type,p_currency_code,p_country_code,p_city,p_address) $$;

create or replace function private.command_add_business_customer(
  p_business_id uuid,
  p_customer_id uuid,
  p_local_display_name text,
  p_credit_limit numeric default null,
  p_default_due_days smallint default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid; v_link public.customer_link_status;
begin
  if not private.is_business_member(p_business_id, array['owner','admin','accountant','cashier']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  if not exists(select 1 from public.customers where id=p_customer_id and status='active') then
    raise exception 'Customer not found';
  end if;

  select case when user_id is null then 'unlinked'::public.customer_link_status else 'pending'::public.customer_link_status end
    into v_link from public.customers where id=p_customer_id;

  insert into public.business_customers(
    business_id, customer_id, local_display_name, credit_limit, default_due_days, link_status, created_by_user_id
  ) values (
    p_business_id,p_customer_id,trim(p_local_display_name),p_credit_limit,p_default_due_days,v_link,(select auth.uid())
  )
  on conflict (business_id, customer_id) do update
    set local_display_name=excluded.local_display_name,
        credit_limit=coalesce(excluded.credit_limit, public.business_customers.credit_limit),
        default_due_days=coalesce(excluded.default_due_days, public.business_customers.default_due_days),
        is_archived=false
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.add_business_customer(
  p_business_id uuid,
  p_customer_id uuid,
  p_local_display_name text,
  p_credit_limit numeric default null,
  p_default_due_days smallint default null
)
returns uuid language sql set search_path=''
as $$ select private.command_add_business_customer(p_business_id,p_customer_id,p_local_display_name,p_credit_limit,p_default_due_days) $$;

create or replace function private.command_request_customer_link(p_business_customer_id uuid)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_user uuid; v_request uuid; v_target_user uuid;
begin
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or not private.is_business_member(v_bc.business_id, array['owner','admin','accountant','cashier']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select user_id into v_target_user from public.customers where id=v_bc.customer_id and status='active';
  if v_target_user is null then raise exception 'Customer has no registered account'; end if;

  update public.customer_link_requests set status='cancelled', updated_at=now()
  where business_customer_id=p_business_customer_id and status='pending';

  v_user := (select auth.uid());
  insert into public.customer_link_requests(business_customer_id,requested_by_user_id,target_customer_id)
  values(p_business_customer_id,v_user,v_bc.customer_id) returning id into v_request;
  update public.business_customers set link_status='pending' where id=p_business_customer_id;

  perform private.enqueue_notification(v_target_user,'link_request','طلب ربط جديد','أرسل محل طلبًا لربط حسابك.','link_request',v_request,
    jsonb_build_object('business_customer_id',p_business_customer_id));
  return v_request;
end;
$$;

create or replace function public.request_customer_link(p_business_customer_id uuid)
returns uuid language sql set search_path=''
as $$ select private.command_request_customer_link(p_business_customer_id) $$;

create or replace function private.command_respond_link_request(p_request_id uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_req public.customer_link_requests%rowtype; v_bc public.business_customers%rowtype; v_owner uuid;
begin
  select * into v_req from public.customer_link_requests where id=p_request_id for update;
  if not found or v_req.status <> 'pending' or v_req.expires_at < now() then raise exception 'Invalid or expired request'; end if;
  if not private.is_customer_owner(v_req.target_customer_id) then raise exception 'Not authorized' using errcode='42501'; end if;
  select * into v_bc from public.business_customers where id=v_req.business_customer_id;

  update public.customer_link_requests
    set status=case when p_accept then 'accepted' else 'rejected' end,
        responded_by_user_id=(select auth.uid()), responded_at=now(), updated_at=now()
    where id=p_request_id;
  update public.business_customers
    set link_status=case when p_accept then 'linked' else 'rejected' end
    where id=v_req.business_customer_id;

  select owner_user_id into v_owner from public.businesses where id=v_bc.business_id;
  perform private.enqueue_notification(v_owner,'link_request',
    case when p_accept then 'تم قبول الربط' else 'تم رفض الربط' end,
    case when p_accept then 'وافق العميل على ربط الحساب.' else 'رفض العميل طلب ربط الحساب.' end,
    'link_request',p_request_id,'{}'::jsonb);
end;
$$;

create or replace function public.respond_link_request(p_request_id uuid, p_accept boolean)
returns void language sql set search_path=''
as $$ select private.command_respond_link_request(p_request_id,p_accept) $$;

-- ---------- Ledger invariants and commands ----------
create or replace function private.validate_ledger_entry_insert()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_currency text; v_original public.ledger_entries%rowtype;
begin
  select * into v_bc from public.business_customers where id=new.business_customer_id;
  if not found or v_bc.business_id <> new.business_id or v_bc.customer_id <> new.customer_id then
    raise exception 'Ledger tenant/customer mismatch';
  end if;
  select currency_code into v_currency from public.businesses where id=new.business_id and status='active';
  if v_currency is null or v_currency <> new.currency_code then raise exception 'Currency or business status mismatch'; end if;
  if not private.is_business_member(new.business_id, array['owner','admin','accountant','cashier']::public.business_role[]) then
    raise exception 'Not authorized to create ledger entries' using errcode='42501';
  end if;
  if new.entry_type='opening_balance' and not private.is_business_member(new.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Opening balance requires elevated role' using errcode='42501';
  end if;
  if new.entry_type='reversal' then
    select * into v_original from public.ledger_entries where id=new.reversal_of_entry_id for update;
    if not found or v_original.business_id<>new.business_id or v_original.customer_id<>new.customer_id then raise exception 'Invalid reversal target'; end if;
    if v_original.entry_type='reversal' then raise exception 'A reversal cannot reverse another reversal'; end if;
    if new.amount<>v_original.amount or new.currency_code<>v_original.currency_code then raise exception 'Reversal must match original amount and currency'; end if;
    if new.direction = v_original.direction then raise exception 'Reversal direction must be opposite'; end if;
  end if;
  return new;
end;
$$;

create trigger trg_validate_ledger_entry
before insert on public.ledger_entries
for each row execute function private.validate_ledger_entry_insert();

create or replace function private.after_ledger_entry_insert()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_customer_user uuid; v_link public.customer_link_status; v_confirmation public.entry_confirmation_status; v_owner uuid;
begin
  select c.user_id, bc.link_status into v_customer_user, v_link
  from public.customers c join public.business_customers bc on bc.customer_id=c.id
  where c.id=new.customer_id and bc.id=new.business_customer_id;

  v_confirmation := case when v_customer_user is not null and v_link='linked' then 'pending' else 'not_available' end;
  insert into public.ledger_entry_state(entry_id,confirmation_status) values(new.id,v_confirmation);
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id)
  values(new.id,new.business_id,new.customer_id,'created',new.created_by_user_id);

  if new.entry_type='reversal' then
    update public.ledger_entry_state set is_reversed=true,reversal_entry_id=new.id,last_event_at=now()
      where entry_id=new.reversal_of_entry_id;
    insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id,metadata)
      values(new.reversal_of_entry_id,new.business_id,new.customer_id,'reversed',new.created_by_user_id,jsonb_build_object('reversal_entry_id',new.id));
  end if;

  if v_customer_user is not null and v_link='linked' then
    perform private.enqueue_notification(v_customer_user,'ledger_created',
      case when new.entry_type='payment' then 'تم تسجيل دفعة' else 'تم تسجيل عملية جديدة' end,
      'راجع العملية الجديدة وقم بتأكيدها أو الاعتراض عليها.',
      'ledger_entry',new.id,jsonb_build_object('business_id',new.business_id,'entry_type',new.entry_type,'amount',new.amount));
    insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id)
      values(new.id,new.business_id,new.customer_id,'notification_queued',new.created_by_user_id);
  end if;
  return new;
end;
$$;

create trigger trg_after_ledger_entry
after insert on public.ledger_entries
for each row execute function private.after_ledger_entry_insert();

create or replace function private.command_create_ledger_entry(
  p_business_customer_id uuid,
  p_entry_type public.ledger_entry_type,
  p_amount numeric,
  p_description text,
  p_occurred_at timestamptz default now(),
  p_due_date date default null,
  p_external_reference text default null,
  p_client_request_id uuid default gen_random_uuid(),
  p_source_device_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_currency varchar(3); v_balance numeric(20,4); v_direction public.ledger_direction; v_id uuid;
begin
  if p_entry_type not in ('opening_balance','debt','payment') then raise exception 'Use reverse_ledger_entry for reversals'; end if;
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then raise exception 'Business customer not found or archived'; end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant','cashier']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
  if p_amount is null or p_amount<=0 then raise exception 'Amount must be positive'; end if;

  select coalesce(sum(case when direction='debit' then amount else -amount end),0)
    into v_balance from public.ledger_entries where business_customer_id=p_business_customer_id;
  if p_entry_type='payment' and p_amount>v_balance then raise exception 'Payment exceeds current balance'; end if;
  if v_bc.credit_limit is not null and p_entry_type in ('opening_balance','debt') and v_balance+p_amount>v_bc.credit_limit then
    raise exception 'Credit limit exceeded';
  end if;
  v_direction := case when p_entry_type='payment' then 'credit' else 'debit' end;

  insert into public.ledger_entries(
    business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,
    occurred_at,due_date,external_reference,client_request_id,source_device_id,created_by_user_id
  ) values(
    v_bc.business_id,v_bc.id,v_bc.customer_id,p_entry_type,v_direction,p_amount,v_currency,trim(p_description),
    coalesce(p_occurred_at,now()),case when p_entry_type='debt' then p_due_date else null end,p_external_reference,
    coalesce(p_client_request_id,gen_random_uuid()),p_source_device_id,(select auth.uid())
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.create_ledger_entry(
  p_business_customer_id uuid,
  p_entry_type public.ledger_entry_type,
  p_amount numeric,
  p_description text,
  p_occurred_at timestamptz default now(),
  p_due_date date default null,
  p_external_reference text default null,
  p_client_request_id uuid default gen_random_uuid(),
  p_source_device_id uuid default null
)
returns uuid language sql set search_path=''
as $$ select private.command_create_ledger_entry(p_business_customer_id,p_entry_type,p_amount,p_description,p_occurred_at,p_due_date,p_external_reference,p_client_request_id,p_source_device_id) $$;

create or replace function private.command_reverse_ledger_entry(
  p_entry_id uuid,
  p_reason text,
  p_client_request_id uuid default gen_random_uuid()
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_original public.ledger_entries%rowtype; v_id uuid; v_direction public.ledger_direction;
begin
  select * into v_original from public.ledger_entries where id=p_entry_id for update;
  if not found or v_original.entry_type='reversal' then raise exception 'Invalid original entry'; end if;
  if not private.is_business_member(v_original.business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  if exists(select 1 from public.ledger_entries where reversal_of_entry_id=p_entry_id) then raise exception 'Entry already reversed'; end if;
  v_direction := case when v_original.direction='debit' then 'credit' else 'debit' end;
  insert into public.ledger_entries(
    business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,
    occurred_at,reversal_of_entry_id,client_request_id,created_by_user_id
  ) values(
    v_original.business_id,v_original.business_customer_id,v_original.customer_id,'reversal',v_direction,
    v_original.amount,v_original.currency_code,trim(p_reason),now(),v_original.id,coalesce(p_client_request_id,gen_random_uuid()),(select auth.uid())
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.reverse_ledger_entry(p_entry_id uuid,p_reason text,p_client_request_id uuid default gen_random_uuid())
returns uuid language sql set search_path=''
as $$ select private.command_reverse_ledger_entry(p_entry_id,p_reason,p_client_request_id) $$;

create or replace function private.after_entry_confirmation()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_entry public.ledger_entries%rowtype; v_owner uuid;
begin
  select * into v_entry from public.ledger_entries where id=new.entry_id;
  update public.ledger_entry_state set confirmation_status='confirmed',last_event_at=new.confirmed_at where entry_id=new.entry_id;
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id)
    values(new.entry_id,v_entry.business_id,v_entry.customer_id,'confirmed',new.confirmed_by_user_id);
  select owner_user_id into v_owner from public.businesses where id=v_entry.business_id;
  perform private.enqueue_notification(v_owner,'ledger_confirmed','تم تأكيد العملية','أكد العميل صحة العملية.','ledger_entry',new.entry_id,'{}'::jsonb);
  return new;
end;
$$;

create trigger trg_after_entry_confirmation
after insert on public.entry_confirmations
for each row execute function private.after_entry_confirmation();

create or replace function private.command_confirm_ledger_entry(p_entry_id uuid,p_device_id uuid default null)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_entry public.ledger_entries%rowtype; v_customer uuid; v_id uuid;
begin
  select * into v_entry from public.ledger_entries where id=p_entry_id;
  if not found or not private.is_customer_owner(v_entry.customer_id) then raise exception 'Not authorized' using errcode='42501'; end if;
  select private.current_customer_id() into v_customer;
  if exists(select 1 from public.entry_confirmations where entry_id=p_entry_id) then raise exception 'Entry already confirmed'; end if;
  if exists(select 1 from public.disputes d join public.dispute_state ds on ds.dispute_id=d.id where d.entry_id=p_entry_id and ds.status in ('open','awaiting_merchant','awaiting_customer','escalated')) then
    raise exception 'Entry has an active dispute';
  end if;
  insert into public.entry_confirmations(entry_id,customer_id,confirmed_by_user_id,device_id)
    values(p_entry_id,v_customer,(select auth.uid()),p_device_id) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.confirm_ledger_entry(p_entry_id uuid,p_device_id uuid default null)
returns uuid language sql set search_path=''
as $$ select private.command_confirm_ledger_entry(p_entry_id,p_device_id) $$;

-- ---------- Dispute commands ----------
create or replace function private.command_open_dispute(
  p_entry_id uuid,
  p_reason public.dispute_reason,
  p_description text
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_entry public.ledger_entries%rowtype; v_dispute uuid; v_owner uuid;
begin
  select * into v_entry from public.ledger_entries where id=p_entry_id;
  if not found or not private.is_customer_owner(v_entry.customer_id) then raise exception 'Not authorized' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_entry_id::text,0));
  if exists(select 1 from public.disputes d join public.dispute_state ds on ds.dispute_id=d.id where d.entry_id=p_entry_id and ds.status in ('open','awaiting_merchant','awaiting_customer','escalated')) then
    raise exception 'An active dispute already exists';
  end if;
  insert into public.disputes(entry_id,business_id,customer_id,opened_by_user_id,reason,description)
    values(p_entry_id,v_entry.business_id,v_entry.customer_id,(select auth.uid()),p_reason,trim(p_description)) returning id into v_dispute;
  insert into public.dispute_state(dispute_id,status) values(v_dispute,'awaiting_merchant');
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note) values(v_dispute,'opened',(select auth.uid()),trim(p_description));
  update public.ledger_entry_state set dispute_status='open',last_event_at=now() where entry_id=p_entry_id;
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id,metadata)
    values(p_entry_id,v_entry.business_id,v_entry.customer_id,'disputed',(select auth.uid()),jsonb_build_object('dispute_id',v_dispute));
  select owner_user_id into v_owner from public.businesses where id=v_entry.business_id;
  perform private.enqueue_notification(v_owner,'ledger_disputed','اعتراض جديد','اعترض العميل على عملية مسجلة.','dispute',v_dispute,jsonb_build_object('entry_id',p_entry_id));
  return v_dispute;
end;
$$;

create or replace function public.open_dispute(p_entry_id uuid,p_reason public.dispute_reason,p_description text)
returns uuid language sql set search_path=''
as $$ select private.command_open_dispute(p_entry_id,p_reason,p_description) $$;

create or replace function private.command_add_dispute_message(p_dispute_id uuid,p_message text)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_d public.disputes%rowtype; v_id uuid; v_is_customer boolean; v_target uuid; v_event public.dispute_event_type;
begin
  select * into v_d from public.disputes where id=p_dispute_id;
  if not found then raise exception 'Dispute not found'; end if;
  v_is_customer := private.is_customer_owner(v_d.customer_id);
  if not v_is_customer and not private.is_business_member(v_d.business_id,array['owner','admin','accountant','collector']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  insert into public.dispute_messages(dispute_id,sender_user_id,message)
    values(p_dispute_id,(select auth.uid()),trim(p_message)) returning id into v_id;
  if v_is_customer then
    update public.dispute_state set status='awaiting_merchant' where dispute_id=p_dispute_id;
    v_event := 'customer_replied';
    select owner_user_id into v_target from public.businesses where id=v_d.business_id;
  else
    update public.dispute_state set status='awaiting_customer' where dispute_id=p_dispute_id;
    v_event := 'merchant_requested_information';
    select user_id into v_target from public.customers where id=v_d.customer_id;
  end if;
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note) values(p_dispute_id,v_event,(select auth.uid()),trim(p_message));
  if v_target is not null then perform private.enqueue_notification(v_target,'dispute_reply','رد جديد على الاعتراض','يوجد رد جديد في الاعتراض.','dispute',p_dispute_id,'{}'::jsonb); end if;
  return v_id;
end;
$$;

create or replace function public.add_dispute_message(p_dispute_id uuid,p_message text)
returns uuid language sql set search_path=''
as $$ select private.command_add_dispute_message(p_dispute_id,p_message) $$;

create or replace function private.command_resolve_dispute(
  p_dispute_id uuid,
  p_resolution public.dispute_current_status,
  p_resolution_note text,
  p_corrected_amount numeric default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_d public.disputes%rowtype; v_entry public.ledger_entries%rowtype; v_reversal uuid; v_corrected uuid; v_customer_user uuid; v_event public.dispute_event_type;
begin
  select * into v_d from public.disputes where id=p_dispute_id;
  if not found or not private.is_business_member(v_d.business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  if p_resolution not in ('accepted','partially_accepted','rejected') then raise exception 'Invalid resolution'; end if;
  select * into v_entry from public.ledger_entries where id=v_d.entry_id;

  if p_resolution in ('accepted','partially_accepted') then
    v_reversal := private.command_reverse_ledger_entry(v_entry.id,'تصحيح بسبب اعتراض: '||trim(p_resolution_note),gen_random_uuid());
  end if;
  if p_resolution='partially_accepted' then
    if p_corrected_amount is null or p_corrected_amount<=0 or p_corrected_amount>=v_entry.amount then raise exception 'Corrected amount must be between zero and original amount'; end if;
    v_corrected := private.command_create_ledger_entry(v_entry.business_customer_id,v_entry.entry_type,p_corrected_amount,
      'قيمة مصححة للعملية '||v_entry.id::text,v_entry.occurred_at,v_entry.due_date,v_entry.external_reference,gen_random_uuid(),null);
  end if;

  update public.dispute_state set status=p_resolution,resolution_note=trim(p_resolution_note),resolved_by_user_id=(select auth.uid()),resolved_at=now()
    where dispute_id=p_dispute_id;
  update public.ledger_entry_state set dispute_status='resolved',last_event_at=now() where entry_id=v_entry.id;
  v_event := case p_resolution when 'accepted' then 'accepted' when 'partially_accepted' then 'partially_accepted' else 'rejected' end;
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note,metadata)
    values(p_dispute_id,v_event,(select auth.uid()),trim(p_resolution_note),jsonb_build_object('reversal_entry_id',v_reversal,'corrected_entry_id',v_corrected));
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id,metadata)
    values(v_entry.id,v_entry.business_id,v_entry.customer_id,'dispute_resolved',(select auth.uid()),jsonb_build_object('resolution',p_resolution));
  select user_id into v_customer_user from public.customers where id=v_d.customer_id;
  if v_customer_user is not null then perform private.enqueue_notification(v_customer_user,'dispute_resolved','تمت معالجة الاعتراض','راجع نتيجة الاعتراض داخل التطبيق.','dispute',p_dispute_id,jsonb_build_object('resolution',p_resolution)); end if;
  return coalesce(v_corrected,v_reversal);
end;
$$;

create or replace function public.resolve_dispute(p_dispute_id uuid,p_resolution public.dispute_current_status,p_resolution_note text,p_corrected_amount numeric default null)
returns uuid language sql set search_path=''
as $$ select private.command_resolve_dispute(p_dispute_id,p_resolution,p_resolution_note,p_corrected_amount) $$;

-- ---------- Service-only customer directory RPCs ----------
create or replace function private.service_find_customer_by_phone_hash(p_phone_hash text)
returns table(customer_id uuid,user_id uuid,global_code text,phone_last4 text)
language sql stable security definer set search_path=''
as $$
  select c.id,c.user_id,c.global_code,cc.phone_last4
  from private.customer_contacts cc join public.customers c on c.id=cc.customer_id
  where cc.phone_hash=p_phone_hash and c.status='active'
$$;

create or replace function public.service_find_customer_by_phone_hash(p_phone_hash text)
returns table(customer_id uuid,user_id uuid,global_code text,phone_last4 text)
language sql set search_path=''
as $$ select * from private.service_find_customer_by_phone_hash(p_phone_hash) $$;

create or replace function private.service_upsert_customer_contact(
  p_customer_id uuid,
  p_phone_hash text,
  p_phone_ciphertext bytea,
  p_phone_last4 text,
  p_verified_at timestamptz default null,
  p_key_version smallint default 1
)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  insert into private.customer_contacts(customer_id,phone_hash,phone_ciphertext,phone_last4,verified_at,encryption_key_version)
  values(p_customer_id,p_phone_hash,p_phone_ciphertext,p_phone_last4,p_verified_at,p_key_version)
  on conflict(customer_id) do update set phone_hash=excluded.phone_hash,phone_ciphertext=excluded.phone_ciphertext,
    phone_last4=excluded.phone_last4,verified_at=coalesce(excluded.verified_at,private.customer_contacts.verified_at),
    encryption_key_version=excluded.encryption_key_version,updated_at=now();
end;
$$;

create or replace function public.service_upsert_customer_contact(
  p_customer_id uuid,p_phone_hash text,p_phone_ciphertext bytea,p_phone_last4 text,
  p_verified_at timestamptz default null,p_key_version smallint default 1
)
returns void language sql set search_path=''
as $$ select private.service_upsert_customer_contact(p_customer_id,p_phone_hash,p_phone_ciphertext,p_phone_last4,p_verified_at,p_key_version) $$;

-- ---------- Balance and timeline views ----------
create or replace view public.business_customer_balances
with (security_invoker=true)
as
select
  bc.id as business_customer_id,
  bc.business_id,
  bc.customer_id,
  bc.local_display_name,
  b.currency_code,
  coalesce(sum(case when le.direction='debit' then le.amount else -le.amount end),0)::numeric(20,4) as current_balance,
  coalesce(sum(case when le.due_date < current_date and le.direction='debit' and not les.is_reversed then le.amount else 0 end),0)::numeric(20,4) as gross_overdue_debits,
  count(le.id) as entry_count,
  max(le.occurred_at) as last_entry_at
from public.business_customers bc
join public.businesses b on b.id=bc.business_id
left join public.ledger_entries le on le.business_customer_id=bc.id
left join public.ledger_entry_state les on les.entry_id=le.id
group by bc.id,bc.business_id,bc.customer_id,bc.local_display_name,b.currency_code;

create or replace view public.ledger_timeline
with (security_invoker=true)
as
select le.*,les.confirmation_status,les.dispute_status,les.is_reversed,les.reversal_entry_id
from public.ledger_entries le join public.ledger_entry_state les on les.entry_id=le.id;

create or replace view public.customer_business_summary
with (security_invoker=true)
as
select bcb.business_customer_id,bcb.business_id,b.name as business_name,b.business_type,b.logo_path,
       bcb.customer_id,bcb.currency_code,bcb.current_balance,bcb.entry_count,bcb.last_entry_at
from public.business_customer_balances bcb join public.businesses b on b.id=bcb.business_id;

commit;

-- Debt Ledger MVP - Offline-first platform hardening, workflow guards and automation foundation
begin;

-- ---------- Offline-first devices and command receipts ----------
create table public.device_installations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  platform text not null check (platform in ('android','ios','web')),
  device_name text,
  app_version text,
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, device_id)
);

create table public.command_receipts (
  idempotency_key uuid primary key,
  user_id uuid not null references auth.users(id) on delete restrict,
  device_id uuid,
  command_type text not null check (command_type in ('create_ledger_entry','reverse_ledger_entry','confirm_ledger_entry','open_dispute','add_dispute_message','resolve_dispute')),
  status text not null check (status in ('accepted','rejected')),
  result_entity_id uuid,
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.sync_checkpoints (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  business_id uuid references public.businesses(id) on delete cascade,
  cursor_value timestamptz not null default 'epoch'::timestamptz,
  updated_at timestamptz not null default now(),
  unique nulls not distinct (user_id, device_id, business_id)
);

-- ---------- Automation and delivery observability ----------
create table public.business_automation_settings (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  timezone text not null default 'Asia/Aden',
  send_from_local_time time not null default '08:00',
  send_until_local_time time not null default '20:00',
  allow_push boolean not null default true,
  updated_at timestamptz not null default now(),
  check (send_from_local_time < send_until_local_time)
);

create table public.automation_rules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  rule_key text not null,
  trigger_type text not null check (trigger_type in ('before_due','on_due','after_due','dispute_sla')),
  offset_days smallint not null default 0 check (offset_days between -365 and 365),
  channel public.reminder_channel not null default 'push',
  message_template text not null check (char_length(trim(message_template)) between 1 and 1000),
  is_active boolean not null default true,
  created_by_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, rule_key)
);

create table public.automation_runs (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null references public.automation_rules(id) on delete restrict,
  business_customer_id uuid references public.business_customers(id) on delete restrict,
  ledger_entry_id uuid references public.ledger_entries(id) on delete restrict,
  run_key text not null unique,
  status text not null default 'queued' check (status in ('queued','running','succeeded','skipped','failed')),
  result jsonb not null default '{}'::jsonb,
  attempted_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.upload_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  entity_type text not null check (entity_type in ('ledger_entry','dispute_message')),
  entity_id uuid not null,
  bucket_id text not null default 'ledger-documents',
  object_path text not null unique,
  original_filename text not null,
  mime_type text not null,
  expected_size_bytes bigint not null check (expected_size_bytes > 0 and expected_size_bytes <= 10485760),
  expected_sha256_hex text check (expected_sha256_hex is null or expected_sha256_hex ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create table private.notification_delivery_attempts (
  id bigint generated always as identity primary key,
  outbox_id bigint not null references private.notification_outbox(id) on delete cascade,
  provider text not null,
  device_token_id uuid references public.device_push_tokens(id) on delete set null,
  status text not null check (status in ('sent','failed','skipped')),
  provider_response jsonb,
  error text,
  created_at timestamptz not null default now()
);

create table private.dead_letter_jobs (
  id bigint generated always as identity primary key,
  job_type text not null,
  source_id text not null,
  error text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique (job_type, source_id)
);

create table private.rate_limit_windows (
  scope text not null,
  subject_key text not null,
  window_started_at timestamptz not null,
  hit_count integer not null default 0 check (hit_count >= 0),
  primary key (scope, subject_key, window_started_at)
);

create index idx_automation_runs_ready on public.automation_runs(status, created_at) where status in ('queued','failed');
create index idx_delivery_attempts_outbox on private.notification_delivery_attempts(outbox_id, created_at desc);
create index idx_command_receipts_user_time on public.command_receipts(user_id, created_at desc);
create index idx_upload_sessions_owner_expiry on public.upload_sessions(user_id, expires_at) where consumed_at is null;

-- ---------- Helpers used by RLS and Edge Functions ----------
create or replace function private.can_customer_access_business_customer(p_business_customer_id uuid)
returns boolean
language sql stable security definer set search_path=''
as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.business_customers bc
    where bc.id=p_business_customer_id
      and bc.link_status='linked'
      and private.is_customer_owner(bc.customer_id)
  )
$$;

create or replace function private.can_access_ledger_entry(p_entry_id uuid)
returns boolean
language sql stable security definer set search_path=''
as $$
  select exists (
    select 1
    from public.ledger_entries le
    where le.id=p_entry_id
      and (
        private.is_business_member(le.business_id,null)
        or private.can_customer_access_business_customer(le.business_customer_id)
      )
  )
$$;

create or replace function private.service_consume_rate_limit(
  p_scope text,
  p_subject_key text,
  p_max_hits integer,
  p_window_seconds integer default 3600
)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_window timestamptz; v_hits integer;
begin
  if p_max_hits < 1 or p_window_seconds < 1 then
    raise exception 'Invalid rate-limit configuration' using errcode='22023';
  end if;
  v_window := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into private.rate_limit_windows(scope,subject_key,window_started_at,hit_count)
  values(p_scope,p_subject_key,v_window,1)
  on conflict(scope,subject_key,window_started_at) do update
    set hit_count=private.rate_limit_windows.hit_count+1
  returning hit_count into v_hits;
  if v_hits > p_max_hits then
    raise exception 'Rate limit exceeded' using errcode='42901';
  end if;
end;
$$;

create or replace function public.service_consume_rate_limit(
  p_scope text,p_subject_key text,p_max_hits integer,p_window_seconds integer default 3600
)
returns void language sql set search_path=''
as $$ select private.service_consume_rate_limit(p_scope,p_subject_key,p_max_hits,p_window_seconds) $$;

create or replace function private.service_record_notification_delivery_attempt(
  p_outbox_id bigint,
  p_provider text,
  p_device_token_id uuid,
  p_status text,
  p_provider_response jsonb default null,
  p_error text default null
)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  if p_status not in ('sent','failed','skipped') then
    raise exception 'Invalid delivery attempt status' using errcode='22023';
  end if;
  insert into private.notification_delivery_attempts(outbox_id,provider,device_token_id,status,provider_response,error)
  values(p_outbox_id,p_provider,p_device_token_id,p_status,p_provider_response,left(p_error,2000));
end;
$$;

create or replace function public.service_record_notification_delivery_attempt(
  p_outbox_id bigint,p_provider text,p_device_token_id uuid,p_status text,p_provider_response jsonb default null,p_error text default null
)
returns void language sql set search_path=''
as $$ select private.service_record_notification_delivery_attempt(p_outbox_id,p_provider,p_device_token_id,p_status,p_provider_response,p_error) $$;

create or replace function private.service_fail_notification(p_outbox_id bigint,p_error text)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_attempt smallint; v_notification_id uuid;
begin
  select attempt_count,notification_id into v_attempt,v_notification_id
  from private.notification_outbox where id=p_outbox_id for update;
  if not found then return; end if;
  if v_attempt >= 8 then
    update private.notification_outbox set processed_at=now(),locked_at=null,last_error=left(p_error,2000) where id=p_outbox_id;
    update public.notifications set delivery_status='failed' where id=v_notification_id;
    insert into private.dead_letter_jobs(job_type,source_id,error,payload)
    values('notification',p_outbox_id::text,left(p_error,2000),jsonb_build_object('notification_id',v_notification_id,'attempt_count',v_attempt))
    on conflict(job_type,source_id) do nothing;
  else
    update private.notification_outbox
    set locked_at=null,last_error=left(p_error,2000),
        available_at=now()+make_interval(secs => least(21600,(power(2,least(v_attempt,8))::integer*60)))
    where id=p_outbox_id;
    update public.notifications set delivery_status='queued' where id=v_notification_id;
  end if;
end;
$$;

-- ---------- Idempotent ledger commands ----------
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
declare
  v_bc public.business_customers%rowtype;
  v_currency varchar(3);
  v_balance numeric(20,4);
  v_direction public.ledger_direction;
  v_id uuid;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  if p_entry_type not in ('opening_balance','debt','payment') then
    raise exception 'Use reverse_ledger_entry for reversals';
  end if;
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then
    raise exception 'Business customer not found or archived';
  end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant','cashier']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select id into v_id from public.ledger_entries
    where business_id=v_bc.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
  if v_currency is null then raise exception 'Business is not active'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Amount must be positive'; end if;
  select coalesce(sum(case when direction='debit' then amount else -amount end),0)
    into v_balance from public.ledger_entries where business_customer_id=p_business_customer_id;
  if p_entry_type='payment' and p_amount>v_balance then raise exception 'Payment exceeds current balance'; end if;
  if v_bc.credit_limit is not null and p_entry_type in ('opening_balance','debt') and v_balance+p_amount>v_bc.credit_limit then
    raise exception 'Credit limit exceeded';
  end if;
  v_direction:=case when p_entry_type='payment' then 'credit' else 'debit' end;
  insert into public.ledger_entries(
    business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,
    occurred_at,due_date,external_reference,client_request_id,source_device_id,created_by_user_id
  ) values(
    v_bc.business_id,v_bc.id,v_bc.customer_id,p_entry_type,v_direction,p_amount,v_currency,trim(p_description),
    coalesce(p_occurred_at,now()),case when p_entry_type='debt' then p_due_date else null end,p_external_reference,
    v_request_id,p_source_device_id,(select auth.uid())
  ) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,device_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),p_source_device_id,'create_ledger_entry','accepted',v_id,jsonb_build_object('entry_id',v_id))
  on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function private.command_reverse_ledger_entry(
  p_entry_id uuid,p_reason text,p_client_request_id uuid default gen_random_uuid()
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_original public.ledger_entries%rowtype;
  v_id uuid;
  v_direction public.ledger_direction;
  v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  select * into v_original from public.ledger_entries where id=p_entry_id for update;
  if not found or v_original.entry_type='reversal' then raise exception 'Invalid original entry'; end if;
  if not private.is_business_member(v_original.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select id into v_id from public.ledger_entries
    where business_id=v_original.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  if exists(select 1 from public.ledger_entries where reversal_of_entry_id=p_entry_id) then raise exception 'Entry already reversed'; end if;
  v_direction:=case when v_original.direction='debit' then 'credit' else 'debit' end;
  insert into public.ledger_entries(
    business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,
    occurred_at,reversal_of_entry_id,client_request_id,created_by_user_id
  ) values(
    v_original.business_id,v_original.business_customer_id,v_original.customer_id,'reversal',v_direction,
    v_original.amount,v_original.currency_code,trim(p_reason),now(),v_original.id,v_request_id,(select auth.uid())
  ) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'reverse_ledger_entry','accepted',v_id,jsonb_build_object('entry_id',v_id))
  on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

-- ---------- Customer visibility and final dispute-state guards ----------
create or replace function private.command_confirm_ledger_entry(p_entry_id uuid,p_device_id uuid default null)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_entry public.ledger_entries%rowtype; v_customer uuid; v_id uuid;
begin
  select * into v_entry from public.ledger_entries where id=p_entry_id;
  if not found or not private.is_customer_owner(v_entry.customer_id)
     or not private.can_customer_access_business_customer(v_entry.business_customer_id) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
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

create or replace function private.command_open_dispute(p_entry_id uuid,p_reason public.dispute_reason,p_description text)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_entry public.ledger_entries%rowtype; v_dispute uuid; v_owner uuid;
begin
  select * into v_entry from public.ledger_entries where id=p_entry_id;
  if not found or not private.is_customer_owner(v_entry.customer_id)
     or not private.can_customer_access_business_customer(v_entry.business_customer_id) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
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

create or replace function private.command_add_dispute_message(p_dispute_id uuid,p_message text)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_d public.disputes%rowtype;
  v_status public.dispute_current_status;
  v_id uuid;
  v_is_customer boolean;
  v_target uuid;
  v_event public.dispute_event_type;
begin
  select * into v_d from public.disputes where id=p_dispute_id;
  if not found then raise exception 'Dispute not found'; end if;
  select status into v_status from public.dispute_state where dispute_id=p_dispute_id for update;
  if not found then raise exception 'Dispute state not found'; end if;
  if v_status not in ('awaiting_merchant','awaiting_customer','open') then
    raise exception 'Dispute is already resolved' using errcode='55000';
  end if;
  v_is_customer:=private.is_customer_owner(v_d.customer_id)
    and private.can_customer_access_business_customer((select business_customer_id from public.ledger_entries where id=v_d.entry_id));
  if not v_is_customer and not private.is_business_member(v_d.business_id,array['owner','admin','accountant','collector']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  insert into public.dispute_messages(dispute_id,sender_user_id,message)
  values(p_dispute_id,(select auth.uid()),trim(p_message)) returning id into v_id;
  if v_is_customer then
    update public.dispute_state set status='awaiting_merchant' where dispute_id=p_dispute_id;
    v_event:='customer_replied';
    select owner_user_id into v_target from public.businesses where id=v_d.business_id;
  else
    update public.dispute_state set status='awaiting_customer' where dispute_id=p_dispute_id;
    v_event:='merchant_requested_information';
    select user_id into v_target from public.customers where id=v_d.customer_id;
  end if;
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note)
  values(p_dispute_id,v_event,(select auth.uid()),trim(p_message));
  if v_target is not null then
    perform private.enqueue_notification(v_target,'dispute_reply','رد جديد على الاعتراض','يوجد رد جديد في الاعتراض.','dispute',p_dispute_id,'{}'::jsonb);
  end if;
  return v_id;
end;
$$;

create or replace function private.command_resolve_dispute(
  p_dispute_id uuid,p_resolution public.dispute_current_status,p_resolution_note text,p_corrected_amount numeric default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_d public.disputes%rowtype;
  v_current public.dispute_current_status;
  v_entry public.ledger_entries%rowtype;
  v_reversal uuid;
  v_corrected uuid;
  v_customer_user uuid;
  v_event public.dispute_event_type;
begin
  select * into v_d from public.disputes where id=p_dispute_id;
  if not found then raise exception 'Dispute not found'; end if;
  select status into v_current from public.dispute_state where dispute_id=p_dispute_id for update;
  if not found then raise exception 'Dispute state not found'; end if;
  if not found or not private.is_business_member(v_d.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  if v_current not in ('open','awaiting_merchant','awaiting_customer','escalated') then
    raise exception 'Dispute is already resolved' using errcode='55000';
  end if;
  if p_resolution not in ('accepted','partially_accepted','rejected') then raise exception 'Invalid resolution'; end if;
  select * into v_entry from public.ledger_entries where id=v_d.entry_id;
  if p_resolution in ('accepted','partially_accepted') then
    v_reversal:=private.command_reverse_ledger_entry(v_entry.id,'تصحيح بسبب اعتراض: '||trim(p_resolution_note),gen_random_uuid());
  end if;
  if p_resolution='partially_accepted' then
    if p_corrected_amount is null or p_corrected_amount<=0 or p_corrected_amount>=v_entry.amount then
      raise exception 'Corrected amount must be between zero and original amount';
    end if;
    v_corrected:=private.command_create_ledger_entry(v_entry.business_customer_id,v_entry.entry_type,p_corrected_amount,
      'قيمة مصححة للعملية '||v_entry.id::text,v_entry.occurred_at,v_entry.due_date,v_entry.external_reference,gen_random_uuid(),null);
  end if;
  update public.dispute_state set status=p_resolution,resolution_note=trim(p_resolution_note),resolved_by_user_id=(select auth.uid()),resolved_at=now()
  where dispute_id=p_dispute_id;
  update public.ledger_entry_state set dispute_status='resolved',last_event_at=now() where entry_id=v_entry.id;
  v_event:=case p_resolution when 'accepted' then 'accepted' when 'partially_accepted' then 'partially_accepted' else 'rejected' end;
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note,metadata)
  values(p_dispute_id,v_event,(select auth.uid()),trim(p_resolution_note),jsonb_build_object('reversal_entry_id',v_reversal,'corrected_entry_id',v_corrected));
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id,metadata)
  values(v_entry.id,v_entry.business_id,v_entry.customer_id,'dispute_resolved',(select auth.uid()),jsonb_build_object('resolution',p_resolution));
  select user_id into v_customer_user from public.customers where id=v_d.customer_id;
  if v_customer_user is not null then
    perform private.enqueue_notification(v_customer_user,'dispute_resolved','تمت معالجة الاعتراض','راجع نتيجة الاعتراض داخل التطبيق.','dispute',p_dispute_id,jsonb_build_object('resolution',p_resolution));
  end if;
  return coalesce(v_corrected,v_reversal);
end;
$$;

-- Replace customer-facing read policies so an unaccepted link never exposes ledger data.
drop policy ledger_entries_select_allowed on public.ledger_entries;
create policy ledger_entries_select_allowed on public.ledger_entries for select to authenticated
using (private.is_business_member(business_id,null) or private.can_customer_access_business_customer(business_customer_id));
drop policy ledger_events_select_allowed on public.ledger_entry_events;
create policy ledger_events_select_allowed on public.ledger_entry_events for select to authenticated
using (private.is_business_member(business_id,null) or exists(
  select 1 from public.ledger_entries le where le.id=ledger_entry_events.entry_id
    and private.can_customer_access_business_customer(le.business_customer_id)
));
drop policy disputes_select_allowed on public.disputes;
create policy disputes_select_allowed on public.disputes for select to authenticated
using (private.is_business_member(business_id,null) or exists(
  select 1 from public.ledger_entries le where le.id=disputes.entry_id
    and private.can_customer_access_business_customer(le.business_customer_id)
));
drop policy dispute_state_select_allowed on public.dispute_state;
create policy dispute_state_select_allowed on public.dispute_state for select to authenticated
using (exists(select 1 from public.disputes d join public.ledger_entries le on le.id=d.entry_id
  where d.id=dispute_state.dispute_id and (private.is_business_member(d.business_id,null) or private.can_customer_access_business_customer(le.business_customer_id))));
drop policy dispute_events_select_allowed on public.dispute_events;
create policy dispute_events_select_allowed on public.dispute_events for select to authenticated
using (exists(select 1 from public.disputes d join public.ledger_entries le on le.id=d.entry_id
  where d.id=dispute_events.dispute_id and (private.is_business_member(d.business_id,null) or private.can_customer_access_business_customer(le.business_customer_id))));
drop policy dispute_messages_select_allowed on public.dispute_messages;
create policy dispute_messages_select_allowed on public.dispute_messages for select to authenticated
using (exists(select 1 from public.disputes d join public.ledger_entries le on le.id=d.entry_id
  where d.id=dispute_messages.dispute_id and (private.is_business_member(d.business_id,null) or private.can_customer_access_business_customer(le.business_customer_id))));

-- RLS and grants for new public tables.
alter table public.device_installations enable row level security;
alter table public.command_receipts enable row level security;
alter table public.sync_checkpoints enable row level security;
alter table public.business_automation_settings enable row level security;
alter table public.automation_rules enable row level security;
alter table public.automation_runs enable row level security;
alter table public.upload_sessions enable row level security;
revoke all on public.device_installations,public.command_receipts,public.sync_checkpoints,public.business_automation_settings,public.automation_rules,public.automation_runs from anon,authenticated;
grant select,insert,update on public.device_installations,public.sync_checkpoints to authenticated;
grant select on public.command_receipts,public.business_automation_settings,public.automation_rules,public.automation_runs to authenticated;
grant insert,update,delete on public.automation_rules to authenticated;
grant insert,update on public.business_automation_settings to authenticated;
create policy device_installations_own_all on public.device_installations for all to authenticated
using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
create policy command_receipts_own_select on public.command_receipts for select to authenticated
using (user_id=(select auth.uid()));
create policy sync_checkpoints_own_all on public.sync_checkpoints for all to authenticated
using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
create policy automation_settings_select_staff on public.business_automation_settings for select to authenticated
using (private.is_business_member(business_id,null));
create policy automation_settings_write_admin on public.business_automation_settings for all to authenticated
using (private.is_business_member(business_id,array['owner','admin']::public.business_role[]))
with check (private.is_business_member(business_id,array['owner','admin']::public.business_role[]));
create policy automation_rules_select_staff on public.automation_rules for select to authenticated
using (private.is_business_member(business_id,null));
create policy automation_rules_write_admin on public.automation_rules for all to authenticated
using (private.is_business_member(business_id,array['owner','admin']::public.business_role[]))
with check (private.is_business_member(business_id,array['owner','admin']::public.business_role[]));
create policy automation_runs_select_staff on public.automation_runs for select to authenticated
using (exists(select 1 from public.automation_rules ar where ar.id=automation_runs.rule_id and private.is_business_member(ar.business_id,null)));

grant usage on schema private to authenticated;
grant execute on function private.can_customer_access_business_customer(uuid) to authenticated;
grant execute on function private.can_access_ledger_entry(uuid) to authenticated;
revoke all on function private.service_consume_rate_limit(text,text,integer,integer) from public,anon,authenticated;
revoke all on function public.service_consume_rate_limit(text,text,integer,integer) from public,anon,authenticated;
grant execute on function private.service_consume_rate_limit(text,text,integer,integer) to service_role;
grant execute on function public.service_consume_rate_limit(text,text,integer,integer) to service_role;
revoke all on function private.service_record_notification_delivery_attempt(bigint,text,uuid,text,jsonb,text) from public,anon,authenticated;
revoke all on function public.service_record_notification_delivery_attempt(bigint,text,uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function private.service_record_notification_delivery_attempt(bigint,text,uuid,text,jsonb,text) to service_role;
grant execute on function public.service_record_notification_delivery_attempt(bigint,text,uuid,text,jsonb,text) to service_role;

create trigger trg_device_installations_updated_at before update on public.device_installations
for each row execute function private.set_updated_at();
create trigger trg_business_automation_settings_updated_at before update on public.business_automation_settings
for each row execute function private.set_updated_at();
create trigger trg_automation_rules_updated_at before update on public.automation_rules
for each row execute function private.set_updated_at();

commit;

-- Debt Ledger MVP - Core schema for Supabase/PostgreSQL
-- Generated: 2026-07-12

begin;

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------- Enums ----------
create type public.account_status as enum ('active','suspended','closed');
create type public.business_status as enum ('active','suspended','closed');
create type public.business_role as enum ('owner','admin','accountant','cashier','collector','viewer');
create type public.member_status as enum ('invited','active','suspended','removed');
create type public.customer_status as enum ('active','merged','closed');
create type public.customer_link_status as enum ('unlinked','pending','linked','rejected','blocked');
create type public.link_request_status as enum ('pending','accepted','rejected','expired','cancelled');
create type public.ledger_entry_type as enum ('opening_balance','debt','payment','reversal');
create type public.ledger_direction as enum ('debit','credit');
create type public.entry_confirmation_status as enum ('not_available','pending','confirmed');
create type public.entry_dispute_status as enum ('none','open','resolved');
create type public.entry_event_type as enum ('created','notification_queued','viewed','confirmed','disputed','dispute_resolved','reversed');
create type public.dispute_reason as enum ('wrong_amount','unknown_transaction','duplicate','already_paid','wrong_date','wrong_description','other');
create type public.dispute_event_type as enum ('opened','merchant_requested_information','customer_replied','accepted','partially_accepted','rejected','escalated','closed');
create type public.dispute_current_status as enum ('open','awaiting_merchant','awaiting_customer','accepted','partially_accepted','rejected','escalated','closed');
create type public.notification_type as enum ('link_request','ledger_created','ledger_confirmed','ledger_disputed','dispute_reply','dispute_resolved','payment_due','reminder','security','system');
create type public.notification_delivery_status as enum ('queued','sent','delivered','failed','read');
create type public.reminder_channel as enum ('in_app','push','manual_share');
create type public.reminder_status as enum ('draft','queued','sent','failed');
create type public.statement_scope as enum ('business_customer','customer_consolidated');
create type public.consent_type as enum ('terms','privacy','customer_link','notifications','data_processing');

-- ---------- Common helpers ----------
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function private.prevent_update_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Immutable financial/audit record: % is not allowed', tg_op
    using errcode = '55000';
end;
$$;

-- ---------- Identity ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 2 and 120),
  avatar_path text,
  city text,
  preferred_language text not null default 'ar' check (preferred_language in ('ar','en')),
  status public.account_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  global_code text not null unique default ('CUS-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),
  status public.customer_status not null default 'active',
  merged_into_customer_id uuid references public.customers(id),
  created_at timestamptz not null default now(),
  check ((status = 'merged' and merged_into_customer_id is not null) or status <> 'merged'),
  check (merged_into_customer_id is null or merged_into_customer_id <> id)
);

-- PII is never exposed through the public Data API.
-- phone_ciphertext is produced by an Edge Function using AES-GCM; phone_hash is HMAC-SHA256.
create table private.customer_contacts (
  customer_id uuid primary key references public.customers(id) on delete restrict,
  phone_hash text unique,
  phone_ciphertext bytea,
  phone_last4 text check (phone_last4 is null or phone_last4 ~ '^[0-9]{4}$'),
  encryption_key_version smallint not null default 1,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- Businesses and tenancy ----------
create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete restrict,
  name text not null check (char_length(trim(name)) between 2 and 160),
  business_type text not null,
  currency_code varchar(3) not null check (currency_code ~ '^[A-Z]{3}$'),
  country_code varchar(2) not null default 'YE' check (country_code ~ '^[A-Z]{2}$'),
  city text,
  address text,
  contact_phone_display text,
  logo_path text,
  timezone text not null default 'Asia/Aden',
  status public.business_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.business_members (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  role public.business_role not null,
  status public.member_status not null default 'active',
  invited_by_user_id uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, user_id)
);

create table public.business_customers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  local_display_name text not null check (char_length(trim(local_display_name)) between 2 and 120),
  local_note text,
  credit_limit numeric(20,4) check (credit_limit is null or credit_limit >= 0),
  default_due_days smallint check (default_due_days is null or default_due_days between 0 and 3650),
  link_status public.customer_link_status not null default 'unlinked',
  is_archived boolean not null default false,
  created_by_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, customer_id)
);

create table public.customer_link_requests (
  id uuid primary key default gen_random_uuid(),
  business_customer_id uuid not null references public.business_customers(id) on delete restrict,
  requested_by_user_id uuid not null references auth.users(id),
  target_customer_id uuid not null references public.customers(id) on delete restrict,
  status public.link_request_status not null default 'pending',
  token_hash text unique,
  expires_at timestamptz not null default (now() + interval '7 days'),
  responded_by_user_id uuid references auth.users(id),
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index uq_pending_link_per_business_customer
  on public.customer_link_requests(business_customer_id)
  where status = 'pending';

-- ---------- Immutable ledger ----------
create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  business_customer_id uuid not null references public.business_customers(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  entry_type public.ledger_entry_type not null,
  direction public.ledger_direction not null,
  amount numeric(20,4) not null check (amount > 0),
  currency_code varchar(3) not null check (currency_code ~ '^[A-Z]{3}$'),
  description text not null check (char_length(trim(description)) between 2 and 500),
  occurred_at timestamptz not null default now(),
  due_date date,
  external_reference text,
  reversal_of_entry_id uuid unique references public.ledger_entries(id) on delete restrict,
  client_request_id uuid not null,
  source_device_id uuid,
  created_by_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (business_id, client_request_id),
  check (
    (entry_type in ('opening_balance','debt') and direction = 'debit' and reversal_of_entry_id is null)
    or (entry_type = 'payment' and direction = 'credit' and reversal_of_entry_id is null)
    or (entry_type = 'reversal' and reversal_of_entry_id is not null)
  )
);

-- Mutable projection only; authoritative state remains in event/confirmation/dispute tables.
create table public.ledger_entry_state (
  entry_id uuid primary key references public.ledger_entries(id) on delete restrict,
  confirmation_status public.entry_confirmation_status not null,
  dispute_status public.entry_dispute_status not null default 'none',
  is_reversed boolean not null default false,
  reversal_entry_id uuid references public.ledger_entries(id) on delete restrict,
  last_event_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ledger_entry_events (
  id bigint generated always as identity primary key,
  entry_id uuid not null references public.ledger_entries(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  event_type public.entry_event_type not null,
  actor_user_id uuid references auth.users(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.entry_confirmations (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null unique references public.ledger_entries(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  confirmed_by_user_id uuid not null references auth.users(id),
  device_id uuid,
  confirmed_at timestamptz not null default now()
);

-- ---------- Disputes ----------
create table public.disputes (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.ledger_entries(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  opened_by_user_id uuid not null references auth.users(id),
  reason public.dispute_reason not null,
  description text not null check (char_length(trim(description)) between 5 and 2000),
  created_at timestamptz not null default now()
);

create table public.dispute_state (
  dispute_id uuid primary key references public.disputes(id) on delete restrict,
  status public.dispute_current_status not null default 'awaiting_merchant',
  resolution_note text,
  resolved_by_user_id uuid references auth.users(id),
  resolved_at timestamptz,
  updated_at timestamptz not null default now()
);

-- Active-dispute uniqueness is enforced by a trigger in the command-functions migration.

create table public.dispute_events (
  id bigint generated always as identity primary key,
  dispute_id uuid not null references public.disputes(id) on delete restrict,
  event_type public.dispute_event_type not null,
  actor_user_id uuid not null references auth.users(id),
  note text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.dispute_messages (
  id uuid primary key default gen_random_uuid(),
  dispute_id uuid not null references public.disputes(id) on delete restrict,
  sender_user_id uuid not null references auth.users(id),
  message text not null check (char_length(trim(message)) between 1 and 4000),
  created_at timestamptz not null default now()
);

-- ---------- Files / Storage metadata ----------
create table public.files (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses(id) on delete restrict,
  customer_id uuid references public.customers(id) on delete restrict,
  bucket_id text not null,
  object_path text not null unique,
  original_filename text not null,
  mime_type text not null,
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 10485760),
  sha256_hex text check (sha256_hex is null or sha256_hex ~ '^[0-9a-f]{64}$'),
  uploaded_by_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  check (business_id is not null or customer_id is not null)
);

create table public.ledger_entry_files (
  entry_id uuid not null references public.ledger_entries(id) on delete restrict,
  file_id uuid not null references public.files(id) on delete restrict,
  primary key (entry_id, file_id)
);

create table public.dispute_message_files (
  message_id uuid not null references public.dispute_messages(id) on delete restrict,
  file_id uuid not null references public.files(id) on delete restrict,
  primary key (message_id, file_id)
);

-- ---------- Notifications ----------
create table public.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  platform text not null check (platform in ('android','ios','web')),
  push_token text not null,
  is_active boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, device_id),
  unique (push_token)
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type public.notification_type not null,
  title text not null,
  body text not null,
  entity_type text,
  entity_id uuid,
  data jsonb not null default '{}'::jsonb,
  delivery_status public.notification_delivery_status not null default 'queued',
  read_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Transactional outbox. Only database triggers/functions and service-side workers use it.
create table private.notification_outbox (
  id bigint generated always as identity primary key,
  notification_id uuid not null unique references public.notifications(id) on delete cascade,
  attempt_count smallint not null default 0,
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  processed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now()
);

create table public.reminders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  business_customer_id uuid not null references public.business_customers(id) on delete restrict,
  sent_by_user_id uuid not null references auth.users(id),
  channel public.reminder_channel not null,
  message_snapshot text not null check (char_length(trim(message_snapshot)) between 1 and 1000),
  status public.reminder_status not null default 'draft',
  scheduled_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- Statements ----------
create table public.statements (
  id uuid primary key default gen_random_uuid(),
  scope public.statement_scope not null,
  business_id uuid references public.businesses(id) on delete restrict,
  business_customer_id uuid references public.business_customers(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  period_from timestamptz not null,
  period_to timestamptz not null,
  currency_code varchar(3),
  opening_balance numeric(20,4) not null,
  total_debits numeric(20,4) not null,
  total_credits numeric(20,4) not null,
  closing_balance numeric(20,4) not null,
  verification_code text not null unique,
  pdf_object_path text,
  snapshot_sha256_hex text check (snapshot_sha256_hex is null or snapshot_sha256_hex ~ '^[0-9a-f]{64}$'),
  generated_by_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  check (period_to >= period_from),
  check (
    (scope = 'business_customer' and business_id is not null and business_customer_id is not null)
    or (scope = 'customer_consolidated' and business_id is null and business_customer_id is null)
  )
);

create table public.statement_items (
  id bigint generated always as identity primary key,
  statement_id uuid not null references public.statements(id) on delete restrict,
  entry_id uuid not null references public.ledger_entries(id) on delete restrict,
  item_order integer not null check (item_order > 0),
  occurred_at timestamptz not null,
  description_snapshot text not null,
  debit_amount numeric(20,4) not null default 0 check (debit_amount >= 0),
  credit_amount numeric(20,4) not null default 0 check (credit_amount >= 0),
  running_balance numeric(20,4) not null,
  confirmation_status public.entry_confirmation_status not null,
  unique (statement_id, item_order),
  unique (statement_id, entry_id),
  check ((debit_amount > 0 and credit_amount = 0) or (credit_amount > 0 and debit_amount = 0))
);

-- ---------- Consent and audit ----------
create table public.user_consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type public.consent_type not null,
  document_version text not null,
  granted boolean not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table private.audit_logs (
  id bigint generated always as identity primary key,
  actor_user_id uuid,
  action text not null,
  entity_schema text not null,
  entity_table text not null,
  entity_id text,
  business_id uuid,
  old_data jsonb,
  new_data jsonb,
  request_id text,
  created_at timestamptz not null default now()
);

-- ---------- Indexes ----------
create index idx_business_members_user_active on public.business_members(user_id, business_id) where status = 'active';
create index idx_business_customers_business on public.business_customers(business_id, is_archived, local_display_name);
create index idx_business_customers_customer on public.business_customers(customer_id, link_status);
create index idx_link_requests_target_status on public.customer_link_requests(target_customer_id, status, created_at desc);
create index idx_ledger_business_customer_time on public.ledger_entries(business_customer_id, occurred_at desc, id);
create index idx_ledger_business_time on public.ledger_entries(business_id, occurred_at desc, id);
create index idx_ledger_customer_time on public.ledger_entries(customer_id, occurred_at desc, id);
create index idx_ledger_due_date on public.ledger_entries(business_id, due_date) where due_date is not null;
create index idx_entry_events_entry_time on public.ledger_entry_events(entry_id, created_at desc);
create index idx_disputes_business_time on public.disputes(business_id, created_at desc);
create index idx_disputes_customer_time on public.disputes(customer_id, created_at desc);
create index idx_dispute_messages_time on public.dispute_messages(dispute_id, created_at);
create index idx_notifications_user_unread on public.notifications(user_id, created_at desc) where read_at is null;
create index idx_outbox_ready on private.notification_outbox(available_at, id) where processed_at is null;
create index idx_reminders_business_customer on public.reminders(business_customer_id, created_at desc);
create index idx_statements_customer_time on public.statements(customer_id, created_at desc);
create index idx_audit_entity on private.audit_logs(entity_table, entity_id, created_at desc);

-- ---------- updated_at triggers ----------
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','businesses','business_members','business_customers','customer_link_requests',
    'ledger_entry_state','dispute_state','device_push_tokens','notifications','reminders'
  ] loop
    execute format('create trigger trg_%I_updated_at before update on public.%I for each row execute function private.set_updated_at()', t, t);
  end loop;
end $$;

create trigger trg_customer_contacts_updated_at
before update on private.customer_contacts
for each row execute function private.set_updated_at();

-- Authoritative financial/history records are append-only.
do $$
declare t text;
begin
  foreach t in array array[
    'ledger_entries','ledger_entry_events','entry_confirmations','disputes','dispute_events',
    'dispute_messages','statement_items'
  ] loop
    execute format('create trigger trg_%I_immutable before update or delete on public.%I for each row execute function private.prevent_update_delete()', t, t);
  end loop;
end $$;

commit;

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

-- Debt Ledger MVP - RLS, grants and API boundary
begin;

-- RLS on every exposed table
alter table public.profiles enable row level security;
alter table public.customers enable row level security;
alter table public.businesses enable row level security;
alter table public.business_members enable row level security;
alter table public.business_customers enable row level security;
alter table public.customer_link_requests enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.ledger_entry_state enable row level security;
alter table public.ledger_entry_events enable row level security;
alter table public.entry_confirmations enable row level security;
alter table public.disputes enable row level security;
alter table public.dispute_state enable row level security;
alter table public.dispute_events enable row level security;
alter table public.dispute_messages enable row level security;
alter table public.files enable row level security;
alter table public.ledger_entry_files enable row level security;
alter table public.dispute_message_files enable row level security;
alter table public.device_push_tokens enable row level security;
alter table public.notifications enable row level security;
alter table public.reminders enable row level security;
alter table public.statements enable row level security;
alter table public.statement_items enable row level security;
alter table public.user_consents enable row level security;

-- Default-deny API privileges
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;

-- Read grants; RLS still filters rows.
grant select on public.profiles,public.customers,public.businesses,public.business_members,
  public.business_customers,public.customer_link_requests,public.ledger_entries,
  public.ledger_entry_state,public.ledger_entry_events,public.entry_confirmations,
  public.disputes,public.dispute_state,public.dispute_events,public.dispute_messages,
  public.files,public.ledger_entry_files,public.dispute_message_files,
  public.device_push_tokens,public.notifications,public.reminders,public.statements,
  public.statement_items,public.user_consents to authenticated;

grant select on public.business_customer_balances,public.ledger_timeline,public.customer_business_summary to authenticated;

-- Restricted direct mutations.
grant update(display_name,avatar_path,city,preferred_language) on public.profiles to authenticated;
grant update(name,business_type,city,address,contact_phone_display,logo_path,timezone) on public.businesses to authenticated;
grant update(local_display_name,local_note,credit_limit,default_due_days,is_archived) on public.business_customers to authenticated;
grant insert,update,delete on public.device_push_tokens to authenticated;
grant update(read_at) on public.notifications to authenticated;
grant insert,update on public.reminders to authenticated;
grant insert on public.user_consents to authenticated;

-- Public command RPCs.
grant execute on function public.create_business(text,text,varchar,varchar,text,text) to authenticated;
grant execute on function public.add_business_customer(uuid,uuid,text,numeric,smallint) to authenticated;
grant execute on function public.request_customer_link(uuid) to authenticated;
grant execute on function public.respond_link_request(uuid,boolean) to authenticated;
grant execute on function public.create_ledger_entry(uuid,public.ledger_entry_type,numeric,text,timestamptz,date,text,uuid,uuid) to authenticated;
grant execute on function public.reverse_ledger_entry(uuid,text,uuid) to authenticated;
grant execute on function public.confirm_ledger_entry(uuid,uuid) to authenticated;
grant execute on function public.open_dispute(uuid,public.dispute_reason,text) to authenticated;
grant execute on function public.add_dispute_message(uuid,text) to authenticated;
grant execute on function public.resolve_dispute(uuid,public.dispute_current_status,text,numeric) to authenticated;

-- Wrappers call private security-definer commands, but private is not an exposed API schema.
grant usage on schema private to authenticated;
grant execute on function private.current_customer_id() to authenticated;
grant execute on function private.is_business_member(uuid,public.business_role[]) to authenticated;
grant execute on function private.is_customer_owner(uuid) to authenticated;
grant execute on function private.can_access_business_customer(uuid) to authenticated;
grant execute on function private.can_access_ledger_entry(uuid) to authenticated;
grant execute on function private.command_create_business(text,text,varchar,varchar,text,text) to authenticated;
grant execute on function private.command_add_business_customer(uuid,uuid,text,numeric,smallint) to authenticated;
grant execute on function private.command_request_customer_link(uuid) to authenticated;
grant execute on function private.command_respond_link_request(uuid,boolean) to authenticated;
grant execute on function private.command_create_ledger_entry(uuid,public.ledger_entry_type,numeric,text,timestamptz,date,text,uuid,uuid) to authenticated;
grant execute on function private.command_reverse_ledger_entry(uuid,text,uuid) to authenticated;
grant execute on function private.command_confirm_ledger_entry(uuid,uuid) to authenticated;
grant execute on function private.command_open_dispute(uuid,public.dispute_reason,text) to authenticated;
grant execute on function private.command_add_dispute_message(uuid,text) to authenticated;
grant execute on function private.command_resolve_dispute(uuid,public.dispute_current_status,text,numeric) to authenticated;

-- Service-only directory RPCs used by Edge Functions.
revoke all on function public.service_find_customer_by_phone_hash(text) from public,anon,authenticated;
revoke all on function public.service_upsert_customer_contact(uuid,text,bytea,text,timestamptz,smallint) from public,anon,authenticated;
grant execute on function public.service_find_customer_by_phone_hash(text) to service_role;
grant execute on function public.service_upsert_customer_contact(uuid,text,bytea,text,timestamptz,smallint) to service_role;
grant usage on schema private to service_role;
grant execute on function private.service_find_customer_by_phone_hash(text) to service_role;
grant execute on function private.service_upsert_customer_contact(uuid,text,bytea,text,timestamptz,smallint) to service_role;

-- ---------- Policies ----------
create policy profiles_select_own on public.profiles for select to authenticated
using ((select auth.uid()) = id);
create policy profiles_update_own on public.profiles for update to authenticated
using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

create policy customers_select_allowed on public.customers for select to authenticated
using (
  private.is_customer_owner(id)
  or exists (
    select 1 from public.business_customers bc
    where bc.customer_id=customers.id and private.is_business_member(bc.business_id,null)
  )
);

create policy businesses_select_allowed on public.businesses for select to authenticated
using (
  private.is_business_member(id,null)
  or exists (
    select 1 from public.business_customers bc
    where bc.business_id=businesses.id and bc.link_status='linked' and private.is_customer_owner(bc.customer_id)
  )
);
create policy businesses_update_admin on public.businesses for update to authenticated
using (private.is_business_member(id,array['owner','admin']::public.business_role[]))
with check (private.is_business_member(id,array['owner','admin']::public.business_role[]));

create policy business_members_select_allowed on public.business_members for select to authenticated
using (
  user_id=(select auth.uid())
  or private.is_business_member(business_id,array['owner','admin']::public.business_role[])
);

create policy business_customers_select_allowed on public.business_customers for select to authenticated
using (
  private.is_business_member(business_id,null)
  or (link_status='linked' and private.is_customer_owner(customer_id))
);
create policy business_customers_update_staff on public.business_customers for update to authenticated
using (private.is_business_member(business_id,array['owner','admin','accountant','cashier']::public.business_role[]))
with check (private.is_business_member(business_id,array['owner','admin','accountant','cashier']::public.business_role[]));

create policy link_requests_select_allowed on public.customer_link_requests for select to authenticated
using (
  private.is_customer_owner(target_customer_id)
  or exists (
    select 1 from public.business_customers bc
    where bc.id=customer_link_requests.business_customer_id and private.is_business_member(bc.business_id,null)
  )
);

create policy ledger_entries_select_allowed on public.ledger_entries for select to authenticated
using (private.is_business_member(business_id,null) or private.is_customer_owner(customer_id));
create policy ledger_state_select_allowed on public.ledger_entry_state for select to authenticated
using (private.can_access_ledger_entry(entry_id));
create policy ledger_events_select_allowed on public.ledger_entry_events for select to authenticated
using (private.is_business_member(business_id,null) or private.is_customer_owner(customer_id));
create policy confirmations_select_allowed on public.entry_confirmations for select to authenticated
using (private.can_access_ledger_entry(entry_id));

create policy disputes_select_allowed on public.disputes for select to authenticated
using (private.is_business_member(business_id,null) or private.is_customer_owner(customer_id));
create policy dispute_state_select_allowed on public.dispute_state for select to authenticated
using (exists(select 1 from public.disputes d where d.id=dispute_state.dispute_id and (private.is_business_member(d.business_id,null) or private.is_customer_owner(d.customer_id))));
create policy dispute_events_select_allowed on public.dispute_events for select to authenticated
using (exists(select 1 from public.disputes d where d.id=dispute_events.dispute_id and (private.is_business_member(d.business_id,null) or private.is_customer_owner(d.customer_id))));
create policy dispute_messages_select_allowed on public.dispute_messages for select to authenticated
using (exists(select 1 from public.disputes d where d.id=dispute_messages.dispute_id and (private.is_business_member(d.business_id,null) or private.is_customer_owner(d.customer_id))));

create policy files_select_allowed on public.files for select to authenticated
using (
  (business_id is not null and private.is_business_member(business_id,null))
  or (customer_id is not null and private.is_customer_owner(customer_id))
);
create policy ledger_entry_files_select_allowed on public.ledger_entry_files for select to authenticated
using (private.can_access_ledger_entry(entry_id));
create policy dispute_message_files_select_allowed on public.dispute_message_files for select to authenticated
using (exists(
  select 1 from public.dispute_messages dm join public.disputes d on d.id=dm.dispute_id
  where dm.id=dispute_message_files.message_id
    and (private.is_business_member(d.business_id,null) or private.is_customer_owner(d.customer_id))
));

create policy push_tokens_own_all on public.device_push_tokens for all to authenticated
using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
create policy notifications_select_own on public.notifications for select to authenticated
using (user_id=(select auth.uid()));
create policy notifications_update_own on public.notifications for update to authenticated
using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));

create policy reminders_select_staff on public.reminders for select to authenticated
using (private.is_business_member(business_id,null));
create policy reminders_insert_staff on public.reminders for insert to authenticated
with check (sent_by_user_id=(select auth.uid()) and private.is_business_member(business_id,array['owner','admin','accountant','cashier','collector']::public.business_role[]));
create policy reminders_update_staff on public.reminders for update to authenticated
using (private.is_business_member(business_id,array['owner','admin','accountant','cashier','collector']::public.business_role[]))
with check (private.is_business_member(business_id,array['owner','admin','accountant','cashier','collector']::public.business_role[]));

create policy statements_select_allowed on public.statements for select to authenticated
using (
  private.is_customer_owner(customer_id)
  or (scope='business_customer' and business_id is not null and private.is_business_member(business_id,null))
);
create policy statement_items_select_allowed on public.statement_items for select to authenticated
using (exists(
  select 1 from public.statements s
  where s.id=statement_items.statement_id
    and (private.is_customer_owner(s.customer_id) or (s.business_id is not null and private.is_business_member(s.business_id,null)))
));

create policy consents_select_own on public.user_consents for select to authenticated
using (user_id=(select auth.uid()));
create policy consents_insert_own on public.user_consents for insert to authenticated
with check (user_id=(select auth.uid()));

commit;

-- Debt Ledger MVP - Supabase Storage and Realtime configuration
begin;

create or replace function private.try_uuid(p_value text)
returns uuid
language plpgsql immutable
set search_path=''
as $$
begin
  return p_value::uuid;
exception when others then
  return null;
end;
$$;

-- Private-by-default buckets. Business logos may be public assets.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values
  ('business-assets','business-assets',true,5242880,array['image/jpeg','image/png','image/webp','image/svg+xml']),
  ('avatars','avatars',false,5242880,array['image/jpeg','image/png','image/webp']),
  ('ledger-documents','ledger-documents',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf']),
  ('statements','statements',false,10485760,array['application/pdf'])
on conflict (id) do update set
  public=excluded.public,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

-- Business asset path: <business_id>/<file>
create policy business_assets_staff_insert on storage.objects
for insert to authenticated
with check (
  bucket_id='business-assets'
  and (storage.foldername(name))[1] is not null
  and private.is_business_member(private.try_uuid((storage.foldername(name))[1]),array['owner','admin']::public.business_role[])
);
create policy business_assets_staff_update on storage.objects
for update to authenticated
using (
  bucket_id='business-assets'
  and private.is_business_member(private.try_uuid((storage.foldername(name))[1]),array['owner','admin']::public.business_role[])
)
with check (
  bucket_id='business-assets'
  and private.is_business_member(private.try_uuid((storage.foldername(name))[1]),array['owner','admin']::public.business_role[])
);
create policy business_assets_staff_delete on storage.objects
for delete to authenticated
using (
  bucket_id='business-assets'
  and private.is_business_member(private.try_uuid((storage.foldername(name))[1]),array['owner','admin']::public.business_role[])
);

-- Avatar path: <auth_user_id>/<file>
create policy avatars_owner_select on storage.objects
for select to authenticated
using (bucket_id='avatars' and private.try_uuid((storage.foldername(name))[1])=(select auth.uid()));
create policy avatars_owner_insert on storage.objects
for insert to authenticated
with check (bucket_id='avatars' and private.try_uuid((storage.foldername(name))[1])=(select auth.uid()));
create policy avatars_owner_update on storage.objects
for update to authenticated
using (bucket_id='avatars' and private.try_uuid((storage.foldername(name))[1])=(select auth.uid()))
with check (bucket_id='avatars' and private.try_uuid((storage.foldername(name))[1])=(select auth.uid()));
create policy avatars_owner_delete on storage.objects
for delete to authenticated
using (bucket_id='avatars' and private.try_uuid((storage.foldername(name))[1])=(select auth.uid()));

-- Ledger-document uploads should use an Edge Function that issues a signed upload URL.
-- Reads are authorized through the public.files metadata table.
create policy ledger_documents_authorized_select on storage.objects
for select to authenticated
using (
  bucket_id='ledger-documents'
  and exists (
    select 1 from public.files f
    where f.bucket_id=storage.objects.bucket_id
      and f.object_path=storage.objects.name
      and (
        (f.business_id is not null and private.is_business_member(f.business_id,null))
        or (f.customer_id is not null and private.is_customer_owner(f.customer_id))
      )
  )
);

create policy statements_authorized_select on storage.objects
for select to authenticated
using (
  bucket_id='statements'
  and exists (
    select 1 from public.statements s
    where s.pdf_object_path=storage.objects.name
      and (
        private.is_customer_owner(s.customer_id)
        or (s.business_id is not null and private.is_business_member(s.business_id,null))
      )
  )
);

-- Realtime: publish only UI state/notification tables, not sensitive PII tables.
do $$
declare t text;
begin
  foreach t in array array['notifications','customer_link_requests','ledger_entry_state','dispute_state','dispute_messages'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I',t);
    end if;
  end loop;
end $$;

alter table public.notifications replica identity full;
alter table public.customer_link_requests replica identity full;
alter table public.ledger_entry_state replica identity full;
alter table public.dispute_state replica identity full;
alter table public.dispute_messages replica identity full;

commit;

-- Debt Ledger MVP - Operational helpers, outbox worker RPCs, audit and scheduled maintenance
begin;

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function private.try_uuid(p_value text)
returns uuid
language plpgsql immutable
set search_path=''
as $$
begin
  return p_value::uuid;
exception when others then
  return null;
end;
$$;

-- Generic audit for mutable business state. Financial facts remain in append-only tables.
create or replace function private.audit_row_change()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_old jsonb; v_new jsonb; v_row jsonb; v_entity_id text; v_business uuid;
begin
  v_old := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end;
  v_new := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end;
  v_row := coalesce(v_new,v_old);
  v_entity_id := coalesce(v_row->>'id',v_row->>'entry_id',v_row->>'dispute_id');
  begin v_business := nullif(v_row->>'business_id','')::uuid; exception when others then v_business := null; end;
  insert into private.audit_logs(actor_user_id,action,entity_schema,entity_table,entity_id,business_id,old_data,new_data,request_id)
  values((select auth.uid()),tg_op,tg_table_schema,tg_table_name,v_entity_id,v_business,v_old,v_new,coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb->>'x-request-id');
  return coalesce(new,old);
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['businesses','business_members','business_customers','customer_link_requests','ledger_entry_state','dispute_state','reminders'] loop
    execute format('create trigger trg_%I_audit after insert or update or delete on public.%I for each row execute function private.audit_row_change()',t,t);
  end loop;
end $$;

-- Claim a push-notification batch atomically (SKIP LOCKED permits multiple workers).
create or replace function private.service_claim_notification_batch(p_limit integer default 100)
returns table(
  outbox_id bigint,
  notification_id uuid,
  user_id uuid,
  notification_type public.notification_type,
  title text,
  body text,
  data jsonb
)
language sql volatile security definer set search_path=''
as $$
  with candidates as (
    select o.id
    from private.notification_outbox o
    where o.processed_at is null
      and o.available_at <= now()
      and (o.locked_at is null or o.locked_at < now()-interval '5 minutes')
    order by o.id
    for update skip locked
    limit greatest(1,least(p_limit,500))
  ), claimed as (
    update private.notification_outbox o
    set locked_at=now(),attempt_count=o.attempt_count+1
    from candidates c
    where o.id=c.id
    returning o.id,o.notification_id
  )
  select c.id,n.id,n.user_id,n.type,n.title,n.body,n.data
  from claimed c join public.notifications n on n.id=c.notification_id
  order by c.id
$$;

create or replace function public.service_claim_notification_batch(p_limit integer default 100)
returns table(outbox_id bigint,notification_id uuid,user_id uuid,notification_type public.notification_type,title text,body text,data jsonb)
language sql set search_path=''
as $$ select * from private.service_claim_notification_batch(p_limit) $$;

create or replace function private.service_complete_notification(p_outbox_id bigint)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  update private.notification_outbox set processed_at=now(),locked_at=null,last_error=null where id=p_outbox_id;
  update public.notifications n set delivery_status='sent'
  from private.notification_outbox o where o.id=p_outbox_id and n.id=o.notification_id;
end;
$$;

create or replace function public.service_complete_notification(p_outbox_id bigint)
returns void language sql set search_path=''
as $$ select private.service_complete_notification(p_outbox_id) $$;

create or replace function private.service_fail_notification(p_outbox_id bigint,p_error text)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_attempt smallint;
begin
  select attempt_count into v_attempt from private.notification_outbox where id=p_outbox_id;
  update private.notification_outbox
  set locked_at=null,last_error=left(p_error,2000),
      available_at=now()+make_interval(secs => least(21600,(power(2,least(coalesce(v_attempt,1),8))::integer*60)))
  where id=p_outbox_id;
  update public.notifications n set delivery_status='failed'
  from private.notification_outbox o where o.id=p_outbox_id and n.id=o.notification_id;
end;
$$;

create or replace function public.service_fail_notification(p_outbox_id bigint,p_error text)
returns void language sql set search_path=''
as $$ select private.service_fail_notification(p_outbox_id,p_error) $$;

-- Expire stale link requests and restore the business-customer link state.
create or replace function private.expire_link_requests()
returns integer
language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
  with expired as (
    update public.customer_link_requests
      set status='expired',updated_at=now()
    where status='pending' and expires_at<now()
    returning business_customer_id
  )
  update public.business_customers bc set link_status='unlinked'
  where bc.id in (select business_customer_id from expired) and bc.link_status='pending';
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;

-- Idempotent schedule creation.
do $$
begin
  if not exists(select 1 from cron.job where jobname='expire-customer-link-requests') then
    perform cron.schedule('expire-customer-link-requests','*/15 * * * *','select private.expire_link_requests();');
  end if;
end $$;

-- Lock down service worker RPCs.
revoke all on function private.service_claim_notification_batch(integer) from public,anon,authenticated;
revoke all on function private.service_complete_notification(bigint) from public,anon,authenticated;
revoke all on function private.service_fail_notification(bigint,text) from public,anon,authenticated;
revoke all on function public.service_claim_notification_batch(integer) from public,anon,authenticated;
revoke all on function public.service_complete_notification(bigint) from public,anon,authenticated;
revoke all on function public.service_fail_notification(bigint,text) from public,anon,authenticated;
grant execute on function public.service_claim_notification_batch(integer) to service_role;
grant execute on function public.service_complete_notification(bigint) to service_role;
grant execute on function public.service_fail_notification(bigint,text) to service_role;
grant execute on function private.service_claim_notification_batch(integer) to service_role;
grant execute on function private.service_complete_notification(bigint) to service_role;
grant execute on function private.service_fail_notification(bigint,text) to service_role;

commit;

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

-- Debt Ledger MVP - Correct enum assignments and link-response command
begin;

create or replace function private.command_respond_link_request(p_request_id uuid,p_accept boolean)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_req public.customer_link_requests%rowtype; v_bc public.business_customers%rowtype; v_owner uuid;
begin
  select * into v_req from public.customer_link_requests where id=p_request_id for update;
  if not found or v_req.status<>'pending' or v_req.expires_at<now() then
    raise exception 'Invalid or expired request';
  end if;
  if not private.is_customer_owner(v_req.target_customer_id) then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select * into v_bc from public.business_customers where id=v_req.business_customer_id;
  update public.customer_link_requests
  set status=case when p_accept then 'accepted'::public.link_request_status else 'rejected'::public.link_request_status end,
      responded_by_user_id=(select auth.uid()),responded_at=now(),updated_at=now()
  where id=p_request_id;
  update public.business_customers
  set link_status=case when p_accept then 'linked'::public.customer_link_status else 'rejected'::public.customer_link_status end
  where id=v_req.business_customer_id;
  select owner_user_id into v_owner from public.businesses where id=v_bc.business_id;
  perform private.enqueue_notification(
    v_owner,'link_request',case when p_accept then 'تم قبول الربط' else 'تم رفض الربط' end,
    case when p_accept then 'وافق العميل على ربط الحساب.' else 'رفض العميل طلب ربط الحساب.' end,
    'link_request',p_request_id,'{}'::jsonb
  );
end;
$$;

create or replace function private.command_create_ledger_entry(
  p_business_customer_id uuid,p_entry_type public.ledger_entry_type,p_amount numeric,p_description text,
  p_occurred_at timestamptz default now(),p_due_date date default null,p_external_reference text default null,
  p_client_request_id uuid default gen_random_uuid(),p_source_device_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_currency varchar(3); v_balance numeric(20,4); v_direction public.ledger_direction; v_id uuid; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  if p_entry_type not in ('opening_balance','debt','payment') then raise exception 'Use reverse_ledger_entry for reversals'; end if;
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then raise exception 'Business customer not found or archived'; end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant','cashier']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  select id into v_id from public.ledger_entries where business_id=v_bc.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
  if v_currency is null then raise exception 'Business is not active'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Amount must be positive'; end if;
  select coalesce(sum(case when direction='debit' then amount else -amount end),0) into v_balance from public.ledger_entries where business_customer_id=p_business_customer_id;
  if p_entry_type='payment' and p_amount>v_balance then raise exception 'Payment exceeds current balance'; end if;
  if v_bc.credit_limit is not null and p_entry_type in ('opening_balance','debt') and v_balance+p_amount>v_bc.credit_limit then raise exception 'Credit limit exceeded'; end if;
  v_direction:=case when p_entry_type='payment' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;
  insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,occurred_at,due_date,external_reference,client_request_id,source_device_id,created_by_user_id)
  values(v_bc.business_id,v_bc.id,v_bc.customer_id,p_entry_type,v_direction,p_amount,v_currency,trim(p_description),coalesce(p_occurred_at,now()),case when p_entry_type='debt' then p_due_date else null end,p_external_reference,v_request_id,p_source_device_id,(select auth.uid())) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,device_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),p_source_device_id,'create_ledger_entry','accepted',v_id,jsonb_build_object('entry_id',v_id)) on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function private.command_reverse_ledger_entry(p_entry_id uuid,p_reason text,p_client_request_id uuid default gen_random_uuid())
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_original public.ledger_entries%rowtype; v_id uuid; v_direction public.ledger_direction; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  select * into v_original from public.ledger_entries where id=p_entry_id for update;
  if not found or v_original.entry_type='reversal' then raise exception 'Invalid original entry'; end if;
  if not private.is_business_member(v_original.business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  select id into v_id from public.ledger_entries where business_id=v_original.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  if exists(select 1 from public.ledger_entries where reversal_of_entry_id=p_entry_id) then raise exception 'Entry already reversed'; end if;
  v_direction:=case when v_original.direction='debit' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;
  insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,occurred_at,reversal_of_entry_id,client_request_id,created_by_user_id)
  values(v_original.business_id,v_original.business_customer_id,v_original.customer_id,'reversal',v_direction,v_original.amount,v_original.currency_code,trim(p_reason),now(),v_original.id,v_request_id,(select auth.uid())) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'reverse_ledger_entry','accepted',v_id,jsonb_build_object('entry_id',v_id)) on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function private.command_resolve_dispute(p_dispute_id uuid,p_resolution public.dispute_current_status,p_resolution_note text,p_corrected_amount numeric default null)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_d public.disputes%rowtype; v_current public.dispute_current_status; v_entry public.ledger_entries%rowtype; v_reversal uuid; v_corrected uuid; v_customer_user uuid; v_event public.dispute_event_type;
begin
  select * into v_d from public.disputes where id=p_dispute_id;
  if not found then raise exception 'Dispute not found'; end if;
  select status into v_current from public.dispute_state where dispute_id=p_dispute_id for update;
  if not found then raise exception 'Dispute state not found'; end if;
  if not private.is_business_member(v_d.business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  if v_current not in ('open','awaiting_merchant','awaiting_customer','escalated') then raise exception 'Dispute is already resolved' using errcode='55000'; end if;
  if p_resolution not in ('accepted','partially_accepted','rejected') then raise exception 'Invalid resolution'; end if;
  select * into v_entry from public.ledger_entries where id=v_d.entry_id;
  if p_resolution in ('accepted','partially_accepted') then v_reversal:=private.command_reverse_ledger_entry(v_entry.id,'تصحيح بسبب اعتراض: '||trim(p_resolution_note),gen_random_uuid()); end if;
  if p_resolution='partially_accepted' then
    if p_corrected_amount is null or p_corrected_amount<=0 or p_corrected_amount>=v_entry.amount then raise exception 'Corrected amount must be between zero and original amount'; end if;
    v_corrected:=private.command_create_ledger_entry(v_entry.business_customer_id,v_entry.entry_type,p_corrected_amount,'قيمة مصححة للعملية '||v_entry.id::text,v_entry.occurred_at,v_entry.due_date,v_entry.external_reference,gen_random_uuid(),null);
  end if;
  update public.dispute_state set status=p_resolution,resolution_note=trim(p_resolution_note),resolved_by_user_id=(select auth.uid()),resolved_at=now() where dispute_id=p_dispute_id;
  update public.ledger_entry_state set dispute_status='resolved',last_event_at=now() where entry_id=v_entry.id;
  v_event:=case p_resolution when 'accepted' then 'accepted'::public.dispute_event_type when 'partially_accepted' then 'partially_accepted'::public.dispute_event_type else 'rejected'::public.dispute_event_type end;
  insert into public.dispute_events(dispute_id,event_type,actor_user_id,note,metadata) values(p_dispute_id,v_event,(select auth.uid()),trim(p_resolution_note),jsonb_build_object('reversal_entry_id',v_reversal,'corrected_entry_id',v_corrected));
  insert into public.ledger_entry_events(entry_id,business_id,customer_id,event_type,actor_user_id,metadata) values(v_entry.id,v_entry.business_id,v_entry.customer_id,'dispute_resolved',(select auth.uid()),jsonb_build_object('resolution',p_resolution));
  select user_id into v_customer_user from public.customers where id=v_d.customer_id;
  if v_customer_user is not null then perform private.enqueue_notification(v_customer_user,'dispute_resolved','تمت معالجة الاعتراض','راجع نتيجة الاعتراض داخل التطبيق.','dispute',p_dispute_id,jsonb_build_object('resolution',p_resolution)); end if;
  return coalesce(v_corrected,v_reversal);
end;
$$;

commit;

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

-- Debt Ledger MVP - Introduce a customer discount ledger type.
-- Kept separate because PostgreSQL requires enum values to commit before constraints use them.
alter type public.ledger_entry_type add value if not exists 'discount' after 'payment';


-- Debt Ledger MVP - Professional double-entry accounting layer
-- Adds a business chart of accounts and automatically journals every ledger event.

begin;

create type public.account_class as enum ('asset','liability','equity','revenue','expense');
create type public.account_normal_balance as enum ('debit','credit');
create type public.accounting_account_status as enum ('active','inactive');
create type public.accounting_period_status as enum ('open','closed');
create type public.journal_entry_status as enum ('posted','voided');

create table public.chart_of_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  parent_account_id uuid references public.chart_of_accounts(id) on delete restrict,
  account_code varchar(12) not null check (account_code ~ '^[0-9]{4,12}$'),
  account_name text not null check (char_length(trim(account_name)) between 2 and 160),
  account_class public.account_class not null,
  normal_balance public.account_normal_balance not null,
  is_control_account boolean not null default false,
  allows_manual_posting boolean not null default true,
  status public.accounting_account_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,account_code),
  check (
    (account_class in ('asset','expense') and normal_balance='debit')
    or (account_class in ('liability','equity','revenue') and normal_balance='credit')
  )
);

create table public.business_accounting_settings (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  accounts_receivable_account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  cash_account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  sales_revenue_account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  sales_discount_account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  opening_balance_equity_account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  allow_customer_credit_balance boolean not null default true,
  updated_at timestamptz not null default now(),
  check (accounts_receivable_account_id <> cash_account_id),
  check (sales_revenue_account_id <> sales_discount_account_id)
);

create table public.accounting_periods (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  period_start date not null,
  period_end date not null,
  status public.accounting_period_status not null default 'open',
  closed_by_user_id uuid references auth.users(id) on delete restrict,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,period_start,period_end),
  check(period_end >= period_start),
  check((status='closed' and closed_by_user_id is not null and closed_at is not null) or status='open')
);

create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  entry_number bigint generated always as identity unique,
  business_id uuid not null references public.businesses(id) on delete restrict,
  source_ledger_entry_id uuid unique references public.ledger_entries(id) on delete restrict,
  source_type text not null check(source_type in ('ledger_entry','manual_adjustment')),
  source_reference text,
  entry_date date not null,
  description text not null check(char_length(trim(description)) between 2 and 500),
  status public.journal_entry_status not null default 'posted',
  posted_by_user_id uuid not null references auth.users(id) on delete restrict,
  posted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check((source_type='ledger_entry' and source_ledger_entry_id is not null) or (source_type='manual_adjustment' and source_ledger_entry_id is null))
);

create table public.journal_entry_lines (
  id bigint generated always as identity primary key,
  journal_entry_id uuid not null references public.journal_entries(id) on delete restrict,
  line_number smallint not null check(line_number > 0),
  account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  business_customer_id uuid references public.business_customers(id) on delete restrict,
  description text,
  debit_amount numeric(20,4) not null default 0 check(debit_amount >= 0),
  credit_amount numeric(20,4) not null default 0 check(credit_amount >= 0),
  created_at timestamptz not null default now(),
  unique(journal_entry_id,line_number),
  check((debit_amount > 0 and credit_amount=0) or (credit_amount > 0 and debit_amount=0))
);

create index idx_chart_of_accounts_business_class on public.chart_of_accounts(business_id,account_class,account_code);
create index idx_journal_entries_business_date on public.journal_entries(business_id,entry_date desc,entry_number desc);
create index idx_journal_lines_account on public.journal_entry_lines(account_id,journal_entry_id);
create index idx_journal_lines_business_customer on public.journal_entry_lines(business_customer_id,journal_entry_id) where business_customer_id is not null;

alter table public.chart_of_accounts enable row level security;
alter table public.business_accounting_settings enable row level security;
alter table public.accounting_periods enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_entry_lines enable row level security;

revoke all on public.chart_of_accounts,public.business_accounting_settings,public.accounting_periods,public.journal_entries,public.journal_entry_lines from anon,authenticated;
grant select on public.chart_of_accounts,public.business_accounting_settings,public.accounting_periods,public.journal_entries,public.journal_entry_lines to authenticated;

create policy chart_of_accounts_select_member on public.chart_of_accounts for select to authenticated
using(private.is_business_member(business_id,null));
create policy accounting_settings_select_member on public.business_accounting_settings for select to authenticated
using(private.is_business_member(business_id,null));
create policy accounting_periods_select_member on public.accounting_periods for select to authenticated
using(private.is_business_member(business_id,null));
create policy journal_entries_select_member on public.journal_entries for select to authenticated
using(private.is_business_member(business_id,null));
create policy journal_lines_select_member on public.journal_entry_lines for select to authenticated
using(exists(select 1 from public.journal_entries je where je.id=journal_entry_lines.journal_entry_id and private.is_business_member(je.business_id,null)));

create trigger trg_chart_of_accounts_updated_at before update on public.chart_of_accounts
for each row execute function private.set_updated_at();
create trigger trg_business_accounting_settings_updated_at before update on public.business_accounting_settings
for each row execute function private.set_updated_at();
create trigger trg_accounting_periods_updated_at before update on public.accounting_periods
for each row execute function private.set_updated_at();
create trigger trg_journal_entries_immutable before update or delete on public.journal_entries
for each row execute function private.prevent_update_delete();
create trigger trg_journal_entry_lines_immutable before update or delete on public.journal_entry_lines
for each row execute function private.prevent_update_delete();

create or replace function private.initialize_business_chart(p_business_id uuid)
returns void
language plpgsql security definer set search_path=''
as $$
declare
  v_ar uuid; v_cash uuid; v_sales uuid; v_discount uuid; v_opening uuid;
begin
  insert into public.chart_of_accounts(business_id,account_code,account_name,account_class,normal_balance,is_control_account,allows_manual_posting)
  values
    (p_business_id,'1000','Cash on hand','asset','debit',false,true),
    (p_business_id,'1100','Accounts receivable','asset','debit',true,false),
    (p_business_id,'3100','Opening balance equity','equity','credit',false,false),
    (p_business_id,'4000','Sales revenue','revenue','credit',false,true),
    (p_business_id,'5100','Sales discounts','expense','debit',false,true)
  on conflict(business_id,account_code) do nothing;

  select id into v_cash from public.chart_of_accounts where business_id=p_business_id and account_code='1000';
  select id into v_ar from public.chart_of_accounts where business_id=p_business_id and account_code='1100';
  select id into v_opening from public.chart_of_accounts where business_id=p_business_id and account_code='3100';
  select id into v_sales from public.chart_of_accounts where business_id=p_business_id and account_code='4000';
  select id into v_discount from public.chart_of_accounts where business_id=p_business_id and account_code='5100';
  insert into public.business_accounting_settings(
    business_id,accounts_receivable_account_id,cash_account_id,sales_revenue_account_id,sales_discount_account_id,opening_balance_equity_account_id
  ) values(p_business_id,v_ar,v_cash,v_sales,v_discount,v_opening)
  on conflict(business_id) do nothing;
end;
$$;

create or replace function private.after_business_create_accounting()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  perform private.initialize_business_chart(new.id);
  return new;
end;
$$;

create trigger trg_after_business_create_accounting after insert on public.businesses
for each row execute function private.after_business_create_accounting();

create or replace function private.assert_posting_period_open(p_business_id uuid,p_entry_date date)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  if exists(select 1 from public.accounting_periods where business_id=p_business_id and status='closed' and p_entry_date between period_start and period_end) then
    raise exception 'Accounting period is closed for %',p_entry_date using errcode='55000';
  end if;
end;
$$;

create or replace function private.validate_journal_entry_line()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_business uuid; v_account_business uuid; v_ar uuid; v_bc_business uuid;
begin
  select business_id into v_business from public.journal_entries where id=new.journal_entry_id;
  select business_id into v_account_business from public.chart_of_accounts where id=new.account_id and status='active';
  if v_business is null or v_account_business is null or v_account_business<>v_business then
    raise exception 'Journal line account must be active and belong to the journal business';
  end if;
  if new.business_customer_id is not null then
    select business_id into v_bc_business from public.business_customers where id=new.business_customer_id;
    if v_bc_business is null or v_bc_business<>v_business then raise exception 'Journal line customer must belong to the journal business'; end if;
  end if;
  select accounts_receivable_account_id into v_ar from public.business_accounting_settings where business_id=v_business;
  if new.account_id=v_ar and new.business_customer_id is null then
    raise exception 'Accounts receivable lines require a business customer dimension';
  end if;
  return new;
end;
$$;

create trigger trg_validate_journal_entry_line before insert on public.journal_entry_lines
for each row execute function private.validate_journal_entry_line();

create or replace function private.assert_journal_entry_balanced()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_journal uuid:=coalesce(new.journal_entry_id,old.journal_entry_id); v_debits numeric; v_credits numeric; v_count integer;
begin
  select count(*),coalesce(sum(debit_amount),0),coalesce(sum(credit_amount),0)
    into v_count,v_debits,v_credits from public.journal_entry_lines where journal_entry_id=v_journal;
  if v_count<2 or v_debits<>v_credits then
    raise exception 'Journal entry % is not balanced (debits %, credits %)',v_journal,v_debits,v_credits using errcode='23514';
  end if;
  return null;
end;
$$;

create constraint trigger trg_journal_entry_balanced
after insert or update or delete on public.journal_entry_lines
deferrable initially deferred for each row execute function private.assert_journal_entry_balanced();

create or replace function private.assert_posted_journal_has_lines()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  if new.status='posted' and not exists(select 1 from public.journal_entry_lines where journal_entry_id=new.id) then
    raise exception 'Posted journal entry requires lines' using errcode='23514';
  end if;
  return null;
end;
$$;

create constraint trigger trg_posted_journal_has_lines
after insert on public.journal_entries
deferrable initially deferred for each row execute function private.assert_posted_journal_has_lines();

create or replace function private.post_ledger_entry_journal(p_ledger_entry_id uuid)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_entry public.ledger_entries%rowtype;
  v_journal uuid;
  v_original_journal uuid;
  v_settings public.business_accounting_settings%rowtype;
  v_line_no smallint:=0;
begin
  select * into v_entry from public.ledger_entries where id=p_ledger_entry_id;
  if not found then raise exception 'Ledger entry not found'; end if;
  select id into v_journal from public.journal_entries where source_ledger_entry_id=p_ledger_entry_id;
  if v_journal is not null then return v_journal; end if;
  perform private.assert_posting_period_open(v_entry.business_id,(v_entry.occurred_at at time zone (select timezone from public.businesses where id=v_entry.business_id))::date);
  select * into v_settings from public.business_accounting_settings where business_id=v_entry.business_id;
  if not found then raise exception 'Business accounting settings are not initialized'; end if;

  insert into public.journal_entries(business_id,source_ledger_entry_id,source_type,source_reference,entry_date,description,posted_by_user_id)
  values(v_entry.business_id,v_entry.id,'ledger_entry',v_entry.external_reference,(v_entry.occurred_at at time zone (select timezone from public.businesses where id=v_entry.business_id))::date,
    'Ledger entry '||v_entry.entry_type::text||': '||v_entry.description,v_entry.created_by_user_id)
  returning id into v_journal;

  if v_entry.entry_type='reversal' then
    select id into v_original_journal from public.journal_entries where source_ledger_entry_id=v_entry.reversal_of_entry_id;
    if v_original_journal is null then
      perform private.post_ledger_entry_journal(v_entry.reversal_of_entry_id);
      select id into v_original_journal from public.journal_entries where source_ledger_entry_id=v_entry.reversal_of_entry_id;
    end if;
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount,credit_amount)
    select v_journal,row_number() over(order by line_number)::smallint,account_id,business_customer_id,'Reversal of ledger entry '||v_entry.reversal_of_entry_id::text,
      credit_amount,debit_amount
    from public.journal_entry_lines where journal_entry_id=v_original_journal order by line_number;
    return v_journal;
  end if;

  if v_entry.entry_type in ('opening_balance','debt') then
    v_line_no:=1;
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount)
    values(v_journal,v_line_no,v_settings.accounts_receivable_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
    v_line_no:=2;
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,credit_amount)
    values(v_journal,v_line_no,case when v_entry.entry_type='opening_balance' then v_settings.opening_balance_equity_account_id else v_settings.sales_revenue_account_id end,
      v_entry.business_customer_id,v_entry.description,v_entry.amount);
  elsif v_entry.entry_type='payment' then
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount)
    values(v_journal,1,v_settings.cash_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,credit_amount)
    values(v_journal,2,v_settings.accounts_receivable_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
  elsif v_entry.entry_type='discount' then
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,debit_amount)
    values(v_journal,1,v_settings.sales_discount_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,business_customer_id,description,credit_amount)
    values(v_journal,2,v_settings.accounts_receivable_account_id,v_entry.business_customer_id,v_entry.description,v_entry.amount);
  else
    raise exception 'Unsupported ledger entry type %',v_entry.entry_type;
  end if;
  return v_journal;
end;
$$;

create or replace function private.after_ledger_entry_accounting()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  perform private.post_ledger_entry_journal(new.id);
  return new;
end;
$$;

create trigger trg_after_ledger_entry_accounting after insert on public.ledger_entries
for each row execute function private.after_ledger_entry_accounting();

alter table public.ledger_entries drop constraint ledger_entries_check;
alter table public.ledger_entries add constraint ledger_entries_check check (
  (entry_type in ('opening_balance','debt') and direction='debit' and reversal_of_entry_id is null)
  or (entry_type in ('payment','discount') and direction='credit' and reversal_of_entry_id is null)
  or (entry_type='reversal' and reversal_of_entry_id is not null)
);

create or replace function private.validate_ledger_entry_insert()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_currency text; v_original public.ledger_entries%rowtype;
begin
  select * into v_bc from public.business_customers where id=new.business_customer_id;
  if not found or v_bc.business_id<>new.business_id or v_bc.customer_id<>new.customer_id then raise exception 'Ledger tenant/customer mismatch'; end if;
  select currency_code into v_currency from public.businesses where id=new.business_id and status='active';
  if v_currency is null or v_currency<>new.currency_code then raise exception 'Currency or business status mismatch'; end if;
  if not private.is_business_member(new.business_id,array['owner','admin','accountant','cashier']::public.business_role[]) then raise exception 'Not authorized to create ledger entries' using errcode='42501'; end if;
  if new.entry_type in ('opening_balance','discount') and not private.is_business_member(new.business_id,array['owner','admin','accountant']::public.business_role[]) then
    raise exception '% requires an elevated role',new.entry_type using errcode='42501';
  end if;
  if new.entry_type='reversal' then
    select * into v_original from public.ledger_entries where id=new.reversal_of_entry_id for update;
    if not found or v_original.business_id<>new.business_id or v_original.customer_id<>new.customer_id then raise exception 'Invalid reversal target'; end if;
    if v_original.entry_type='reversal' then raise exception 'A reversal cannot reverse another reversal'; end if;
    if new.amount<>v_original.amount or new.currency_code<>v_original.currency_code then raise exception 'Reversal must match original amount and currency'; end if;
    if new.direction=v_original.direction then raise exception 'Reversal direction must be opposite'; end if;
  end if;
  return new;
end;
$$;

create or replace function private.command_create_ledger_entry(
  p_business_customer_id uuid,p_entry_type public.ledger_entry_type,p_amount numeric,p_description text,
  p_occurred_at timestamptz default now(),p_due_date date default null,p_external_reference text default null,
  p_client_request_id uuid default gen_random_uuid(),p_source_device_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_currency varchar(3); v_balance numeric(20,4); v_direction public.ledger_direction; v_id uuid; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid()); v_allow_credit boolean;
begin
  if p_entry_type not in ('opening_balance','debt','payment') then raise exception 'Use apply_customer_discount or reverse_ledger_entry for this entry type'; end if;
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then raise exception 'Business customer not found or archived'; end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant','cashier']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  select id into v_id from public.ledger_entries where business_id=v_bc.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
  if v_currency is null then raise exception 'Business is not active'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Amount must be positive'; end if;
  select coalesce(sum(case when direction='debit' then amount else -amount end),0) into v_balance from public.ledger_entries where business_customer_id=p_business_customer_id;
  select allow_customer_credit_balance into v_allow_credit from public.business_accounting_settings where business_id=v_bc.business_id;
  if p_entry_type='payment' and p_amount>v_balance and not coalesce(v_allow_credit,true) then raise exception 'Payment exceeds current balance'; end if;
  if v_bc.credit_limit is not null and p_entry_type in ('opening_balance','debt') and v_balance+p_amount>v_bc.credit_limit then raise exception 'Credit limit exceeded'; end if;
  v_direction:=case when p_entry_type='payment' then 'credit'::public.ledger_direction else 'debit'::public.ledger_direction end;
  insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,occurred_at,due_date,external_reference,client_request_id,source_device_id,created_by_user_id)
  values(v_bc.business_id,v_bc.id,v_bc.customer_id,p_entry_type,v_direction,p_amount,v_currency,trim(p_description),coalesce(p_occurred_at,now()),case when p_entry_type='debt' then p_due_date else null end,p_external_reference,v_request_id,p_source_device_id,(select auth.uid())) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,device_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),p_source_device_id,'create_ledger_entry','accepted',v_id,jsonb_build_object('entry_id',v_id)) on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function private.command_apply_customer_discount(
  p_business_customer_id uuid,p_amount numeric,p_description text,p_occurred_at timestamptz default now(),p_client_request_id uuid default gen_random_uuid()
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_bc public.business_customers%rowtype; v_currency varchar(3); v_balance numeric(20,4); v_id uuid; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  select * into v_bc from public.business_customers where id=p_business_customer_id for update;
  if not found or v_bc.is_archived then raise exception 'Business customer not found or archived'; end if;
  if not private.is_business_member(v_bc.business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  select id into v_id from public.ledger_entries where business_id=v_bc.business_id and client_request_id=v_request_id;
  if v_id is not null then return v_id; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Discount amount must be positive'; end if;
  select coalesce(sum(case when direction='debit' then amount else -amount end),0) into v_balance from public.ledger_entries where business_customer_id=p_business_customer_id;
  if v_balance<=0 or p_amount>v_balance then raise exception 'Discount cannot exceed the outstanding debit balance'; end if;
  select currency_code into v_currency from public.businesses where id=v_bc.business_id and status='active';
  if v_currency is null then raise exception 'Business is not active'; end if;
  insert into public.ledger_entries(business_id,business_customer_id,customer_id,entry_type,direction,amount,currency_code,description,occurred_at,client_request_id,created_by_user_id)
  values(v_bc.business_id,v_bc.id,v_bc.customer_id,'discount','credit',p_amount,v_currency,trim(p_description),coalesce(p_occurred_at,now()),v_request_id,(select auth.uid())) returning id into v_id;
  insert into public.command_receipts(idempotency_key,user_id,command_type,status,result_entity_id,result)
  values(v_request_id,(select auth.uid()),'apply_customer_discount','accepted',v_id,jsonb_build_object('entry_id',v_id)) on conflict(idempotency_key) do nothing;
  return v_id;
end;
$$;

create or replace function public.apply_customer_discount(
  p_business_customer_id uuid,p_amount numeric,p_description text,p_occurred_at timestamptz default now(),p_client_request_id uuid default gen_random_uuid()
)
returns uuid language sql set search_path=''
as $$ select private.command_apply_customer_discount(p_business_customer_id,p_amount,p_description,p_occurred_at,p_client_request_id) $$;

create or replace function private.command_post_manual_journal(
  p_business_id uuid,p_entry_date date,p_description text,p_lines jsonb,p_source_reference text default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_journal uuid; v_line jsonb; v_line_number smallint:=0; v_account uuid; v_debit numeric; v_credit numeric;
begin
  if not private.is_business_member(p_business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<2 then raise exception 'Manual journal requires at least two lines'; end if;
  perform private.assert_posting_period_open(p_business_id,p_entry_date);
  insert into public.journal_entries(business_id,source_type,source_reference,entry_date,description,posted_by_user_id)
  values(p_business_id,'manual_adjustment',p_source_reference,p_entry_date,trim(p_description),(select auth.uid())) returning id into v_journal;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_line_number:=v_line_number+1;
    v_account:=(v_line->>'account_id')::uuid;
    v_debit:=coalesce((v_line->>'debit_amount')::numeric,0);
    v_credit:=coalesce((v_line->>'credit_amount')::numeric,0);
    if not exists(select 1 from public.chart_of_accounts where id=v_account and business_id=p_business_id and allows_manual_posting and status='active') then
      raise exception 'Manual posting is not allowed to account %',v_account;
    end if;
    insert into public.journal_entry_lines(journal_entry_id,line_number,account_id,description,debit_amount,credit_amount)
    values(v_journal,v_line_number,v_account,nullif(trim(v_line->>'description'),''),v_debit,v_credit);
  end loop;
  return v_journal;
end;
$$;

create or replace function public.post_manual_journal(
  p_business_id uuid,p_entry_date date,p_description text,p_lines jsonb,p_source_reference text default null
)
returns uuid language sql set search_path=''
as $$ select private.command_post_manual_journal(p_business_id,p_entry_date,p_description,p_lines,p_source_reference) $$;

create or replace function private.command_close_accounting_period(p_business_id uuid,p_period_start date,p_period_end date)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if not private.is_business_member(p_business_id,array['owner','admin','accountant']::public.business_role[]) then raise exception 'Not authorized' using errcode='42501'; end if;
  if p_period_end<p_period_start then raise exception 'Period end must be on or after period start'; end if;
  if exists(select 1 from public.accounting_periods where business_id=p_business_id and status='closed' and daterange(period_start,period_end,'[]') && daterange(p_period_start,p_period_end,'[]')) then
    raise exception 'Accounting period overlaps a closed period';
  end if;
  insert into public.accounting_periods(business_id,period_start,period_end,status,closed_by_user_id,closed_at)
  values(p_business_id,p_period_start,p_period_end,'closed',(select auth.uid()),now()) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.close_accounting_period(p_business_id uuid,p_period_start date,p_period_end date)
returns uuid language sql set search_path=''
as $$ select private.command_close_accounting_period(p_business_id,p_period_start,p_period_end) $$;

create or replace view public.account_trial_balance
with (security_invoker=true)
as
select
  coa.business_id,coa.id as account_id,coa.account_code,coa.account_name,coa.account_class,coa.normal_balance,
  coalesce(sum(jel.debit_amount),0)::numeric(20,4) as total_debits,
  coalesce(sum(jel.credit_amount),0)::numeric(20,4) as total_credits,
  (coalesce(sum(jel.debit_amount),0)-coalesce(sum(jel.credit_amount),0))::numeric(20,4) as signed_balance,
  case when coa.normal_balance='debit' then greatest(coalesce(sum(jel.debit_amount),0)-coalesce(sum(jel.credit_amount),0),0)
       else greatest(coalesce(sum(jel.credit_amount),0)-coalesce(sum(jel.debit_amount),0),0) end::numeric(20,4) as normal_balance_amount
from public.chart_of_accounts coa
left join public.journal_entry_lines jel on jel.account_id=coa.id
group by coa.business_id,coa.id,coa.account_code,coa.account_name,coa.account_class,coa.normal_balance;

create or replace view public.business_customer_account_positions
with (security_invoker=true)
as
select
  bc.id as business_customer_id,bc.business_id,bc.customer_id,bc.local_display_name,b.currency_code,
  coalesce(sum(case when le.direction='debit' then le.amount else -le.amount end),0)::numeric(20,4) as receivable_signed_balance,
  greatest(coalesce(sum(case when le.direction='debit' then le.amount else -le.amount end),0),0)::numeric(20,4) as amount_customer_owes,
  greatest(-coalesce(sum(case when le.direction='debit' then le.amount else -le.amount end),0),0)::numeric(20,4) as amount_business_owes_customer
from public.business_customers bc
join public.businesses b on b.id=bc.business_id
left join public.ledger_entries le on le.business_customer_id=bc.id
group by bc.id,bc.business_id,bc.customer_id,bc.local_display_name,b.currency_code;

-- Existing businesses receive the default chart and every historical ledger item gains one balanced journal entry.
do $$
declare v_business record; v_entry record;
begin
  for v_business in select id from public.businesses loop
    perform private.initialize_business_chart(v_business.id);
  end loop;
  for v_entry in select id from public.ledger_entries order by created_at,id loop
    perform private.post_ledger_entry_journal(v_entry.id);
  end loop;
end $$;

grant select on public.account_trial_balance,public.business_customer_account_positions to authenticated;
grant execute on function public.apply_customer_discount(uuid,numeric,text,timestamptz,uuid) to authenticated;
grant execute on function public.post_manual_journal(uuid,date,text,jsonb,text) to authenticated;
grant execute on function public.close_accounting_period(uuid,date,date) to authenticated;
grant usage on schema private to authenticated;
grant execute on function private.command_apply_customer_discount(uuid,numeric,text,timestamptz,uuid) to authenticated;
grant execute on function private.command_post_manual_journal(uuid,date,text,jsonb,text) to authenticated;
grant execute on function private.command_close_accounting_period(uuid,date,date) to authenticated;

commit;



-- Debt Ledger MVP - Allow accounting commands to participate in offline idempotency receipts.
begin;

alter table public.command_receipts drop constraint command_receipts_command_type_check;
alter table public.command_receipts add constraint command_receipts_command_type_check check (
  command_type in (
    'create_ledger_entry','reverse_ledger_entry','confirm_ledger_entry','open_dispute',
    'add_dispute_message','resolve_dispute','apply_customer_discount','post_manual_journal'
  )
);

commit;

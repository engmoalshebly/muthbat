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

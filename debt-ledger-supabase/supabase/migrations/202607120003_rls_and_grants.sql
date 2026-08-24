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

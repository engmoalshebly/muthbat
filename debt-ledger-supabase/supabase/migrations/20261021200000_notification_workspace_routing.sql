-- Every notification has one explicit product workspace.  The value is derived
-- on the server from the protected entity and recipient, never supplied by a client.
begin;

create or replace function private.enrich_notification_workspace()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  v_business uuid;
  v_customer uuid;
  v_owner uuid;
  v_account text;
  v_entry public.ledger_entries%rowtype;
begin
  if new.entity_type = 'ledger_entry' and new.entity_id is not null then
    select * into v_entry from public.ledger_entries where id = new.entity_id;
    if found then
      v_business := v_entry.business_id;
      v_customer := v_entry.business_customer_id;
      select owner_user_id into v_owner from public.businesses where id = v_business;
      v_account := case when new.user_id = v_owner then 'merchant' else 'customer' end;
      new.data := coalesce(new.data, '{}'::jsonb) || jsonb_build_object(
        'workspace', v_account, 'business_id', v_business,
        'business_customer_id', v_customer, 'currency', v_entry.currency_code
      );
    end if;
  elsif new.entity_type = 'dispute' and new.entity_id is not null then
    select le.* into v_entry
    from public.disputes d join public.ledger_entries le on le.id = d.entry_id
    where d.id = new.entity_id;
    if found then
      select owner_user_id into v_owner from public.businesses where id = v_entry.business_id;
      v_account := case when new.user_id = v_owner then 'merchant' else 'customer' end;
      new.data := coalesce(new.data, '{}'::jsonb) || jsonb_build_object(
        'workspace', v_account, 'business_id', v_entry.business_id,
        'business_customer_id', v_entry.business_customer_id, 'currency', v_entry.currency_code
      );
    end if;
  elsif new.entity_type = 'link_request' then
    v_account := case when new.type = 'link_request' and new.title like 'تم %' then 'merchant' else 'customer' end;
    new.data := coalesce(new.data, '{}'::jsonb) || jsonb_build_object('workspace', v_account);
  else
    new.data := coalesce(new.data, '{}'::jsonb) || jsonb_build_object('workspace', coalesce(new.data->>'workspace', 'merchant'));
  end if;
  return new;
end $$;

drop trigger if exists enrich_notification_workspace on public.notifications;
create trigger enrich_notification_workspace
before insert on public.notifications
for each row execute function private.enrich_notification_workspace();

update public.notifications n
set data = n.data || jsonb_build_object(
  'workspace', case when b.owner_user_id = n.user_id then 'merchant' else 'customer' end,
  'business_id', e.business_id, 'business_customer_id', e.business_customer_id, 'currency', e.currency_code
)
from public.ledger_entries e join public.businesses b on b.id = e.business_id
where n.entity_type = 'ledger_entry' and n.entity_id = e.id;

update public.notifications n
set data = n.data || jsonb_build_object(
  'workspace', case when b.owner_user_id = n.user_id then 'merchant' else 'customer' end,
  'business_id', e.business_id, 'business_customer_id', e.business_customer_id, 'currency', e.currency_code
)
from public.disputes d join public.ledger_entries e on e.id = d.entry_id
join public.businesses b on b.id = e.business_id
where n.entity_type = 'dispute' and n.entity_id = d.id;

update public.notifications
set data = data || jsonb_build_object('workspace', 'merchant')
where not (data ? 'workspace');

create index if not exists idx_notifications_user_workspace_created
on public.notifications(user_id, (data->>'workspace'), created_at desc);

commit;

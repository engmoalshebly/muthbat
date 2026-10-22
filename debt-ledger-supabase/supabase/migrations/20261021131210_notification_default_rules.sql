begin;
create function private.install_default_notification_rules(p_business_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare b public.businesses;
begin
 select * into b from public.businesses where id=p_business_id;
 if not found then return; end if;
 insert into public.business_automation_settings(business_id,timezone)
 values(b.id,b.timezone) on conflict(business_id) do nothing;
 insert into public.automation_rules(business_id,rule_key,trigger_type,offset_days,channel,message_template,created_by_user_id)
 values
 (b.id,'default_due_day','on_due',0,'push','مرحباً {customer_name}، لديك استحقاق اليوم لدى {business_name}. راجع حسابك للاطلاع على العمليات والرصيد الحالي.',b.owner_user_id),
 (b.id,'default_overdue_three_days','after_due',3,'push','مرحباً {customer_name}، لديك استحقاق سابق لدى {business_name}. يرجى مراجعة حسابك والتواصل مع المحل عند الحاجة.',b.owner_user_id),
 (b.id,'default_dispute_two_days','dispute_sla',2,'push','يوجد اعتراض لم تتم معالجته منذ {sla_days} أيام لدى {business_name}. راجع الاعتراض ورد على العميل.',b.owner_user_id)
 on conflict(business_id,rule_key) do nothing;
end $$;
revoke all on function private.install_default_notification_rules(uuid) from public,anon,authenticated;
create function private.after_business_notification_setup() returns trigger
language plpgsql security definer set search_path='' as $$
begin perform private.install_default_notification_rules(new.id); return new; end $$;
revoke all on function private.after_business_notification_setup() from public,anon,authenticated;
create trigger trg_business_notification_setup after insert on public.businesses
for each row execute function private.after_business_notification_setup();
select private.install_default_notification_rules(id) from public.businesses where status='active';
commit;

-- Vault notification_worker_secret must equal Edge NOTIFICATION_WORKER_SECRET.
begin;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
create or replace function private.invoke_notification_worker(p_worker text)
returns bigint language plpgsql security definer set search_path='' as $$
declare v_url text; v_secret text; v_id bigint;
begin
 if p_worker not in ('process-notification-outbox','process-automation-rules') then raise exception 'invalid_worker'; end if;
 select decrypted_secret into v_url from vault.decrypted_secrets where name='notification_project_url';
 select decrypted_secret into v_secret from vault.decrypted_secrets where name='notification_worker_secret';
 if v_url is null or v_url !~ '^https://[a-z0-9]+\.supabase\.co$' or v_secret is null or length(v_secret)<32 then raise exception 'notification_vault_configuration_missing'; end if;
 select net.http_post(url:=v_url || '/functions/v1/' || p_worker,
  headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',v_secret),
  body:='{}'::jsonb,timeout_milliseconds:=120000) into v_id;
 return v_id;
end $$;
revoke all on function private.invoke_notification_worker(text) from public,anon,authenticated;
do $$ declare v_name text; begin
 foreach v_name in array array['notification-outbox-minute','notification-automation-quarter-hour'] loop
  if exists(select 1 from cron.job where jobname=v_name) then perform cron.unschedule(v_name); end if;
 end loop;
end $$;
select cron.schedule('notification-outbox-minute','* * * * *',$job$select private.invoke_notification_worker('process-notification-outbox');$job$);
select cron.schedule('notification-automation-quarter-hour','*/15 * * * *',$job$select private.invoke_notification_worker('process-automation-rules');$job$);
commit;

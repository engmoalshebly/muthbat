import {PGlite} from '../.verification/notification-tests/node_modules/@electric-sql/pglite/dist/index.js';
import {readFile} from 'node:fs/promises';
process.on('uncaughtException',error=>{console.error(error.message,error.where ?? '');process.exit(1);});
const db=new PGlite();
const read=name=>readFile(new URL('../supabase/migrations/'+name,import.meta.url),'utf8');
await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
create schema auth;create schema extensions;create table auth.users(id uuid primary key,raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth to authenticated;grant execute on function auth.uid() to authenticated;`);
await db.exec((await read('202607120001_core_schema.sql')).replace('create extension if not exists pgcrypto with schema extensions;',''));
await db.exec(await read('202607120002_functions_and_triggers.sql'));
await db.exec(await read('202607120003_rls_and_grants.sql'));
const hardening=await read('202608140006_platform_hardening_and_offline.sql');
await db.exec(hardening.slice(hardening.indexOf('create table public.device_installations'),hardening.indexOf('-- ---------- Idempotent ledger commands')));

await db.exec(await read('20261021124307_android_notifications_production.sql'));
await db.exec(await read('20261021131210_notification_default_rules.sql'));
console.log('PASS: migration applies to actual core schema and automation support tables');
await db.exec(await readFile(new URL('../supabase/tests/database/031_android_notifications.sql',import.meta.url),'utf8'));
console.log('PASS: debt/payment generation, unlinked suppression, rotation, account switching, delivery status, deduplication, atomic reminders and RLS');
await db.close();


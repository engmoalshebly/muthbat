-- Run on a local/disposable migrated database with psql -v ON_ERROR_STOP=1.
-- Fixtures and commands are rolled back, including ordinary reversal checks.
begin;
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','b1900000-0000-0000-0000-000000000001','authenticated','authenticated','reversal-time@example.test','unused',now(),'{}','{"display_name":"Reversal test","user_type":"merchant"}',now(),now());
set local role authenticated;
select set_config('request.jwt.claim.sub','b1900000-0000-0000-0000-000000000001',true);
select set_config('test.notebook',jsonb_build_object(
  'version',1,'id','b1900000-0000-0000-0000-000000000002',
  'owner_id','b1900000-0000-0000-0000-000000000001','name','Historical reversal shop','currency','YER',
  'customers',jsonb_build_array(jsonb_build_object('id','b1900000-0000-0000-0000-000000000003','name','Local customer')),
  'entries',jsonb_build_array(
    jsonb_build_object('id','b1900000-0000-0000-0000-000000000004','customer_id','b1900000-0000-0000-0000-000000000003',
      'type','debt','direction','debit','minor',1000000,'description','Historical debt','occurred_at','2026-08-01T10:00:00+03:00'),
    jsonb_build_object('id','b1900000-0000-0000-0000-000000000005','customer_id','b1900000-0000-0000-0000-000000000003',
      'type','payment','direction','credit','minor',200000,'description','Historical payment','occurred_at','2026-08-02T09:00:00+03:00'),
    jsonb_build_object('id','b1900000-0000-0000-0000-000000000006','customer_id','b1900000-0000-0000-0000-000000000003',
      'type','reversal','direction','debit','minor',200000,'description','Historical reversal',
      'occurred_at','2026-08-03T00:15:00+03:00','reverses','b1900000-0000-0000-0000-000000000005')
  ))::text,true);
select set_config('test.result',public.import_local_notebook(current_setting('test.notebook')::jsonb)::text,true);
do $$ declare v_reversal public.ledger_entries%rowtype; v_original uuid; begin
  assert public.local_notebook_import_version()=6, 'Timestamp contract deployed';
  select * into strict v_reversal from public.ledger_entries
    where business_id=(current_setting('test.result')::jsonb->>'business_id')::uuid and entry_type='reversal';
  assert v_reversal.occurred_at='2026-08-02T21:15:00Z'::timestamptz, 'Original instant and timezone preserved';
  assert v_reversal.created_at=transaction_timestamp(), 'Creation time remains import time for incremental sync';
  assert (select entry_date='2026-08-03'::date from public.journal_entries where source_ledger_entry_id=v_reversal.id), 'Journal uses original local calendar date';
  assert public.import_local_notebook(current_setting('test.notebook')::jsonb)=current_setting('test.result')::jsonb, 'Retry returns same receipt';
  assert (select count(*)=1 from public.ledger_entries where business_id=v_reversal.business_id and entry_type='reversal'), 'Retry does not duplicate reversal';
  assert (public.verify_local_notebook_import('b1900000-0000-0000-0000-000000000002')->>'verified')::boolean, 'Financial reconciliation still passes';
  begin
    perform private.command_reverse_ledger_entry_at(v_reversal.reversal_of_entry_id,'Unauthorized backdate',gen_random_uuid(),false,'2020-01-01');
    raise exception 'Caller could backdate financial commands';
  exception when insufficient_privilege then null; end;

  select id into strict v_original from public.ledger_entries
    where business_id=v_reversal.business_id and entry_type='debt';
  v_original := public.reverse_ledger_entry(v_original,'Ordinary reversal',gen_random_uuid());
  select * into strict v_reversal from public.ledger_entries where id=v_original;
  assert v_reversal.occurred_at=transaction_timestamp(), 'Ordinary commands retain server time';
  assert (public.verify_local_notebook_import('b1900000-0000-0000-0000-000000000002')->>'verified')::boolean,
    'New activity after import does not invalidate imported snapshot verification';
end $$;

-- Bad/missing timestamps must not create a partial imported business.
do $$ declare v_bad jsonb; v_id uuid; v_before bigint; begin
  select count(*) into v_before from public.businesses;
  v_id := gen_random_uuid();
  v_bad := jsonb_set(current_setting('test.notebook')::jsonb,'{id}',to_jsonb(v_id));
  v_bad := jsonb_set(v_bad,'{entries,2}',(v_bad->'entries'->2)-'occurred_at');
  begin
    perform public.import_local_notebook(v_bad);
    raise exception 'Missing reversal date accepted';
  exception when invalid_parameter_value then
    if sqlerrm <> 'Reversal date required' then raise; end if;
  end;
  assert (select count(*)=v_before from public.businesses), 'Missing date leaves no partial business';
  v_bad := jsonb_set(v_bad,'{entries,2,occurred_at}','"infinity"');
  begin
    perform public.import_local_notebook(v_bad);
    raise exception 'Infinite reversal date accepted';
  exception when invalid_parameter_value then null; end;
  assert (select count(*)=v_before from public.businesses), 'Invalid date leaves no partial business';
end $$;
rollback;
select 'PASS: original reversal instant, local journal date, server creation time, retry and authorization' as result;

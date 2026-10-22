# Backup and restore runbook (production)

Ledger data is financial. Losing or corrupting it is a release blocker, so
backups are not optional and must be proven by a restore drill before go-live.

## 1. Required settings on `muthbat-prod`

| Setting | Value | Where |
|---|---|---|
| Plan | Pro or higher (needed for PITR) | Dashboard > Billing |
| Point-in-Time Recovery | Enabled, retention 7 days minimum | Dashboard > Database > Backups > PITR add-on |
| Compute | Small or larger (PITR requires it) | Dashboard > Settings > Compute |
| Daily backups | Visible and recent | Dashboard > Database > Backups |

The operator, not CI, enables these. Record the date and the person in the
go-live checklist.

## 2. Targets

- RPO: 2 minutes with PITR (WAL shipping). Never worse than 24 hours.
- RTO: 2 hours to a usable restored database.

## 3. Restore drill (run before go-live, then every quarter)

Never restore over production for a drill. Use a disposable project.

1. Create `muthbat-restore-drill` with `deploy/production/create-project.sh`
   (`SUPABASE_PROJECT_NAME=muthbat-restore-drill`).
2. Restore production backup or a PITR timestamp into it
   (Dashboard > Database > Backups > Restore to a new project).
3. Run the reconciliation checks below against both databases and compare.
4. Record in the table at the bottom: date, backup timestamp, elapsed time,
   result.
5. Delete the drill project.

### Reconciliation checks

Run read-only on production and on the restored copy. For data older than the
restore point every value must match.

```sql
-- Row counts
select 'ledger_entries' as t, count(*) from public.ledger_entries
union all select 'ledger_entry_state',  count(*) from public.ledger_entry_state
union all select 'ledger_entry_events', count(*) from public.ledger_entry_events
union all select 'businesses',          count(*) from public.businesses;

-- Balance checksum per business and currency (debits minus credits)
select business_id, currency_code,
       sum(case direction when 'debit' then amount else -amount end) as balance
from public.ledger_entries
group by 1, 2
order by 1, 2;

-- Integrity: each of these must return zero rows
select e.id from public.ledger_entries e
  left join public.ledger_entry_state s on s.entry_id = e.id
 where s.entry_id is null;                        -- entry without state row

select id from public.ledger_entries
 where reversal_of_entry_id is not null
   and entry_type <> 'reversal';                  -- reversal link on wrong type
```

## 4. Incident: bad data written or table dropped

1. Stop writes: put the app in maintenance by disabling the Edge Functions that
   mutate data and revoking `authenticated` write grants if needed.
2. Pick the restore timestamp just before the damage.
3. Restore to a NEW project, verify with the reconciliation checks.
4. Export the affected rows from the restored project and re-apply them to
   production, or repoint the app after approval by the owner.
5. Write a post-incident note.

## 5. Drill log

| Date | Backup / PITR timestamp | Elapsed | Reconciliation | Operator |
|---|---|---|---|---|
| _pending first drill_ | | | | |

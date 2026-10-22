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
3. Run `tools/restore-reconciliation.sql` (see below) against both databases
   and compare the output.
4. Record in the table at the bottom: date, backup timestamp, elapsed time,
   result.
5. Delete the drill project.

### Reconciliation checks

Run read-only on production and on the restored copy; every value must match
for data older than the restore point.

```sql
select 'profiles'      as t, count(*) from public.profiles
union all select 'businesses',     count(*) from public.businesses
union all select 'ledger_entries', count(*) from public.ledger_entries;

-- Double-entry invariant: must return zero rows
select transaction_id
from public.ledger_entries
group by transaction_id
having sum(case when direction = 'debit' then amount else -amount end) <> 0;
```

If a table or column name above differs from the schema, adapt the query to the
current migration before the drill; the invariant (debits equal credits per
transaction) is what matters.

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

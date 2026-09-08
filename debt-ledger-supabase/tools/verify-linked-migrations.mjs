import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

// Bounded, rollback-only verification. Never run migration commits or reset
// against the linked database. Test fixtures and extension creation roll back.
const root = process.cwd();
const migrations = [
  '202609070001_local_notebook_import.sql',
  '202609080001_customer_phone_claim.sql',
  '202609080002_customer_directory_atomic.sql',
  '202609080003_customer_action_receipts.sql',
];
const tests = process.argv.slice(2);
if (!tests.length || tests.some(t => !/^\d{3}_[a-z_]+\.sql$/.test(t))) throw Error('Provide database test filenames');
function stripTransaction(sql) {
  const stripped = sql.replace(/^\s*(begin|commit|rollback);\s*$/gmi, '');
  if (/^\s*(begin|commit|rollback);/mi.test(stripped)) throw Error('Unexpected transaction boundary');
  return stripped;
}
const bodies = migrations.map(name => stripTransaction(readFileSync(resolve(root,'supabase/migrations',name),'utf8'))).join('\n');
mkdirSync(resolve(root,'.verification'),{recursive:true});
for (const name of tests) {
  const test = stripTransaction(readFileSync(resolve(root,'supabase/tests/database',name),'utf8'))
    .replace(/select\s+(ok|is|throws_ok)\(([\s\S]*?)\);/gi, 'select pg_temp.assert_tap($1($2));')
    .replace(/select \* from finish\(\);/gi, 'select pg_temp.assert_tap(finish());');
  const sql = `begin;
set local lock_timeout='2s';
set local statement_timeout='25s';
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_temp;
create function pg_temp.assert_tap(line text) returns text language plpgsql as $assert$
begin
  if line not like 'ok %' then raise exception 'Verification failed: %',line; end if;
  return line;
end;
$assert$;
${bodies}
${test}
reset role;
select '${name}: rollback verification passed' as verification;
rollback;
`;
  const file = resolve(root,'.verification',name);
  writeFileSync(file,sql);
  const result = spawnSync('supabase',['db','query','--linked','--file',file], {encoding:'utf8',shell:process.platform==='win32',timeout:90000});
  const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  if (result.status !== 0 || /"error"\s*:|Verification failed:/i.test(output)) {
    console.error(output); process.exit(1);
  }
  console.log(`${name}: passed in rolled-back transaction`);
}

// Run: cd supabase/tests && npm install && npm test
// Runs every file in supabase/migrations, in order, against PGlite with a stubbed Supabase auth
// schema, then checks the trigger, constraints, dedupe index and RLS isolation.

import { readFileSync, readdirSync } from 'node:fs';
import assert from 'node:assert/strict';
import { PGlite } from '@electric-sql/pglite';

let sql = readFileSync(new URL('../migrations/0001_init.sql', import.meta.url), 'utf8');

const db = new PGlite();
await db.exec(`
  create schema auth;
  create table auth.users (id uuid primary key);
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  create role authenticated;
`);

// PGlite has no logical replication; check the publication statement separately for syntax only.
const pub = sql.slice(sql.indexOf('create publication'));
sql = sql.slice(0, sql.indexOf('create publication'));
await db.exec(sql);
try { await db.exec(pub); console.log('publication: created'); }
catch (e) { console.log('publication: skipped in PGlite (' + e.message + ')'); }

const dir = new URL('../migrations/', import.meta.url);
for (const f of readdirSync(dir).filter((f) => f.endsWith('.sql') && f !== '0001_init.sql').sort()) {
  await db.exec(readFileSync(new URL(f, dir), 'utf8'));
}

await db.exec(`grant usage on schema auth to authenticated;
  grant execute on function auth.uid() to authenticated;
  grant all on all tables in schema public to authenticated;`);

const A = '11111111-1111-1111-1111-111111111111';
const B = '22222222-2222-2222-2222-222222222222';
await db.exec(`insert into auth.users values ('${A}'), ('${B}')`);

const cats = await db.query(`select count(*)::int n from categories where user_id = $1`, [A]);
assert.equal(cats.rows[0].n, 13, 'default categories seeded');
const settings = await db.query(`select base_currency from user_settings where user_id = $1`, [A]);
assert.equal(settings.rows[0].base_currency, 'IDR', 'settings seeded');

const as = async (uid, q, p) => {
  await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`);
  try { return await db.query(q, p); } finally { await db.exec('reset role'); }
};
const fails = async (uid, q, why) => {
  await assert.rejects(as(uid, q), undefined, why);
};

// User A writes through RLS; user_id comes from auth.uid() default.
const acc = await as(A, `insert into accounts (name, type, provider) values ('GoPay','ewallet','gopay') returning id`);
const acc2 = await as(A, `insert into accounts (name, type) values ('BCA','bank') returning id`);
const accId = acc.rows[0].id, acc2Id = acc2.rows[0].id;
await as(A, `insert into records (account_id, type, amount, currency, source, source_ref)
              values ($1, 'expense', 2500000, 'IDR', 'notification', 'gopay:abc')`, [accId]);
await as(A, `insert into records (account_id, type, amount, currency, transfer_account_id, transfer_amount)
              values ($1, 'transfer', 10000000, 'IDR', $2, 10000000)`, [acc2Id, accId]);

await fails(A, `insert into records (account_id, type, amount, currency, source_ref)
                values ('${accId}', 'expense', 100, 'IDR', 'gopay:abc')`, 'duplicate notification rejected');
await fails(A, `insert into records (account_id, type, amount, currency)
                values ('${accId}', 'transfer', 100, 'IDR')`, 'transfer needs target account');
await fails(A, `insert into records (account_id, type, amount, currency)
                values ('${accId}', 'expense', 0, 'IDR')`, 'zero amount rejected');

// A receipt's lines ride on its record as a JSON array.
await as(A, `insert into records (account_id, type, amount, currency, items)
              values ($1, 'expense', 3300000, 'IDR', '[{"name":"Teh Tarik","qty":1,"amount":3300000}]')`, [accId]);
await fails(A, `insert into records (account_id, type, amount, currency, items)
                values ('${accId}', 'expense', 100, 'IDR', '{"name":"x"}')`, 'items must be an array');

// RLS: B sees none of A's rows and cannot write rows owned by A.
const seen = await as(B, `select (select count(*) from accounts)::int a, (select count(*) from records)::int r,
                                 (select count(*) from categories)::int c`);
assert.deepEqual(seen.rows[0], { a: 0, r: 0, c: 13 }, 'B sees only own rows');
await fails(B, `insert into accounts (user_id, name, type) values ('${A}', 'x', 'cash')`, 'B cannot write as A');

// Balance is derived, not stored: GoPay = -25.000 - 33.000 + 100.000 transfer in = 42.000 (minor units x100).
const bal = await as(A, `
  select a.initial_balance + coalesce(sum(case
      when r.account_id = a.id and r.type = 'income' then r.amount
      when r.account_id = a.id and r.type in ('expense','transfer') then -r.amount
      when r.transfer_account_id = a.id then r.transfer_amount end), 0) as balance
  from accounts a left join records r on a.id in (r.account_id, r.transfer_account_id)
  where a.id = $1 group by a.id`, [accId]);
assert.equal(Number(bal.rows[0].balance), 4200000, 'derived balance');

console.log('migration check: all assertions passed');

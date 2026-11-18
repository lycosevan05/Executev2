import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';

const { PGlite } = await import(process.env.PGLITE_MODULE_PATH ?? '@electric-sql/pglite');
const db = new PGlite();
const migrations = new URL('../../migrations/', import.meta.url);
const tables = [
  'ai_plans', 'app_users', 'custom_checklist_items', 'daily_logs', 'food_logs',
  'goal_progress_entries', 'goals', 'injury_profiles', 'meal_plans',
  'nutrition_profiles', 'readiness_check_ins', 'saved_recipes', 'user_ai_contexts',
  'user_page_layouts', 'user_profiles', 'user_subscriptions', 'workout_logs',
  'workout_plans', 'workout_profiles',
];
const owner = '11111111-1111-1111-1111-111111111111';
const otherOwner = '22222222-2222-2222-2222-222222222222';
const email = 'qa,(exact)"@example.invalid';
const otherEmail = 'other@example.invalid';
const id = (n) => `aaaaaaaa-aaaa-aaaa-aaaa-${String(n).padStart(12, '0')}`;
const results = [];

async function migrate(file, transform = (sql) => sql) {
  await db.exec(transform(await readFile(new URL(file, migrations), 'utf8')));
}

async function test(name, check) {
  await check();
  results.push({ name, result: 'pass' });
  console.log('PASS', name);
}

async function asRole(role, claims, action) {
  assert.ok(['anon', 'authenticated', 'service_role'].includes(role));
  try {
    await db.exec(`set role ${role}`);
    await db.query("select set_config('request.jwt.claims', $1, false)", [JSON.stringify({ role, ...claims })]);
    return await action();
  } finally {
    await db.exec('reset role');
  }
}

function asOwner(action, claims = { sub: owner, email }) {
  return asRole('authenticated', claims, action);
}

async function insert(table, n, { ownerID = null, ownerEmail = null, createdBy = null, userEmail = null, data = {} } = {}) {
  return db.query(
    `insert into public.${table}(id, owner_id, owner_email, created_by, user_email, data)
     values ($1, $2, $3, $4, $5, $6) returning id`,
    [id(n), ownerID, ownerEmail, createdBy, userEmail, JSON.stringify(data)],
  );
}

async function rows(table) {
  return (await db.query(`select id from public.${table} order by id`)).rows.map((row) => row.id);
}

async function policies() {
  return (await db.query('select * from pg_policies order by schemaname, tablename, policyname')).rows;
}

async function rlsState() {
  return (await db.query(`
    select n.nspname, c.relname, c.relrowsecurity, c.relforcerowsecurity
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public', 'storage') and c.relkind = 'r'
    order by n.nspname, c.relname
  `)).rows;
}

async function readRow(table, n) {
  return (await db.query(`select * from public.${table} where id = $1`, [id(n)])).rows[0];
}

try {
  await db.exec(`
    create role anon;
    create role authenticated;
    create role service_role bypassrls;
    create schema auth;
    create schema storage;
    grant usage on schema public, auth, storage to anon, authenticated, service_role;

    create function auth.jwt() returns jsonb language sql stable as $sql$
      select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
    $sql$;
    create function auth.uid() returns uuid language sql stable as $sql$
      select nullif(auth.jwt() ->> 'sub', '')::uuid
    $sql$;
    create function auth.role() returns text language sql stable as $sql$
      select auth.jwt() ->> 'role'
    $sql$;
    create function storage.foldername(name text) returns text[] language sql immutable as $sql$
      select (string_to_array(name, '/'))[1:cardinality(string_to_array(name, '/')) - 1]
    $sql$;
    create table storage.buckets (
      id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]
    );
    create table storage.objects (
      id uuid primary key default gen_random_uuid(), name text not null, bucket_id text not null
    );
    alter table storage.objects enable row level security;
    grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;
  `);

  // PGlite lacks pgcrypto. PostgreSQL itself supplies gen_random_uuid(), which
  // is the only function this baseline uses that the extension also provides.
  await migrate('20260526000000_supabase_backend.sql', (sql) =>
    sql.replace(/^create extension if not exists pgcrypto;\n/, ''));
  await migrate('20261109000000_patch_record_native_updates.sql');

  const tablePrivileges = 'select, insert, update, delete';
  for (const table of tables) {
    await db.exec(`grant ${tablePrivileges} on public.${table} to anon, authenticated, service_role`);
    await insert(table, 1, { ownerID: owner, ownerEmail: otherEmail, data: { retained: true } });
    await insert(table, 2, { ownerEmail: email, userEmail: '', data: { retained: true } });
    await insert(table, 3, { ownerID: otherOwner, ownerEmail: email, createdBy: email });
    await insert(table, 4, { ownerEmail: email, createdBy: otherEmail });
    await insert(table, 5, { ownerEmail: email.toUpperCase() });
    await insert(table, 6, { createdBy: '' });
  }
  await db.exec(`
    create table public.unrelated_fixture (id integer primary key);
    alter table public.unrelated_fixture enable row level security;
    create policy unrelated_fixture_access on public.unrelated_fixture using (true);
    insert into storage.objects (name, bucket_id) values ('seed/path.txt', 'uploads');
  `);

  const baselinePolicies = await policies();
  const baselineRLS = await rlsState();
  const baselineForeign = await asOwner(() => readRow('daily_logs', 3));
  assert.equal(baselineForeign.owner_id, otherOwner);

  await migrate('20261117000000_guard_entity_ownership.sql');

  await test('migration adds exactly 19 restrictive all-operation guards and preserves existing policies and RLS scope', async () => {
    const after = await policies();
    const newPolicies = after.filter((row) => row.policyname === 'entity ownership guard');
    assert.deepEqual(newPolicies.map((row) => row.tablename), tables);
    for (const entry of newPolicies) {
      assert.equal(entry.schemaname, 'public');
      assert.equal(entry.permissive, 'RESTRICTIVE');
      assert.equal(entry.cmd, 'ALL');
      assert.deepEqual(entry.roles, ['public']);
      assert.ok(entry.qual);
      assert.equal(entry.qual, entry.with_check);
    }
    assert.deepEqual(after.filter((row) => row.policyname !== 'entity ownership guard'), baselinePolicies);
    assert.deepEqual(await rlsState(), baselineRLS);
  });

  await test('all entity SELECT policies preserve UUID and consistent legacy owners, reject foreign/ambiguous/blank attribution', async () => {
    for (const table of tables) {
      assert.deepEqual(await asOwner(() => rows(table)), [id(1), id(2)], table);
    }
    assert.deepEqual(await asOwner(() => rows('daily_logs'), { sub: owner }), [id(1)]);
    assert.deepEqual(await asOwner(() => rows('daily_logs'), { sub: owner, email: '' }), [id(1)]);
    assert.deepEqual(await asOwner(() => rows('daily_logs'), { email }), []);
    assert.deepEqual(await asRole('anon', { email }, () => rows('daily_logs')), []);
    assert.deepEqual(
      await asOwner(() => rows('daily_logs'), { sub: otherOwner, email: otherEmail }),
      [id(3)],
    );
  });

  await test('all entity INSERT checks preserve UUID attribution and exact legacy matching', async () => {
    for (const table of tables) {
      await asOwner(() => insert(table, 11, { ownerID: owner, ownerEmail: otherEmail }));
      await asOwner(() => insert(table, 12, { ownerEmail: '', createdBy: email }));
      await asOwner(() => insert(table, 13, { ownerEmail: '', userEmail: email }));
      await assert.rejects(asOwner(() => insert(table, 14, { ownerID: otherOwner, ownerEmail: email })), { code: '42501' });
      await assert.rejects(asOwner(() => insert(table, 15, { ownerEmail: email, userEmail: otherEmail })), { code: '42501' });
    }
    await assert.rejects(asOwner(() => insert('daily_logs', 16, { ownerEmail: email }), { email }), { code: '42501' });
  });

  await test('all entity UPDATE uses previous-row ownership and checks new ownership separately', async () => {
    for (const table of tables) {
      const updateData = (n) => db.query(`update public.${table} set data = data || '{"updated":true}' where id = $1`, [id(n)]);
      const updateOwner = (n, value) => db.query(`update public.${table} set owner_id = $2 where id = $1`, [id(n), value]);
      assert.equal((await asOwner(() => updateData(1))).affectedRows, 1, table);
      assert.equal((await asOwner(() => updateData(2))).affectedRows, 1, table);
      assert.equal((await asOwner(() => updateOwner(3, owner))).affectedRows, 0, table);
      assert.equal((await asOwner(() => updateOwner(4, owner))).affectedRows, 0, table);
      await assert.rejects(asOwner(() => updateOwner(1, otherOwner)), { code: '42501' });
      await assert.rejects(asOwner(() => db.query(
        `update public.${table} set user_email = $2 where id = $1`, [id(2), otherEmail])),
      { code: '42501' });
      assert.equal((await readRow(table, 1)).owner_id, owner);
      assert.equal((await readRow(table, 2)).owner_id, null);
      assert.equal((await readRow(table, 3)).owner_id, otherOwner);
    }
  });

  await test('subscription JSON ownership constrains legacy rows only and cannot replace exact envelope ownership', async () => {
    const table = 'user_subscriptions';
    await insert(table, 21, { ownerEmail: email, data: { user_id: email } });
    await insert(table, 22, { ownerEmail: email, data: { user_id: '' } });
    await insert(table, 23, { ownerEmail: email, data: { user_id: null } });
    await insert(table, 24, { ownerEmail: email, data: { user_id: otherEmail } });
    await insert(table, 25, { ownerID: owner, ownerEmail: otherEmail, data: { user_id: otherEmail } });
    await insert(table, 26, { data: { user_id: email } });
    const visible = await asOwner(() => rows(table));
    for (const number of [21, 22, 23, 25]) assert.ok(visible.includes(id(number)));
    for (const number of [24, 26]) assert.ok(!visible.includes(id(number)));
    await assert.rejects(asOwner(() => insert(table, 27, { ownerEmail: email, data: { user_id: otherEmail } })), { code: '42501' });
    await assert.rejects(asOwner(() => db.query(
      'update public.user_subscriptions set data = $2 where id = $1',
      [id(21), JSON.stringify({ user_id: otherEmail })],
    )), { code: '42501' });
    assert.equal((await readRow(table, 21)).data.user_id, email);
  });

  await test('a broader permissive all-operation policy cannot bypass the restrictive guard', async () => {
    await db.exec('create policy fixture_permissive_all on public.daily_logs for all to authenticated using (true) with check (true)');
    assert.equal(await asOwner(() => readRow('daily_logs', 3)), undefined);
    assert.equal(await asOwner(() => readRow('daily_logs', 6)), undefined);
    await assert.rejects(asOwner(() => insert('daily_logs', 31, {})), { code: '42501' });
    await assert.rejects(asOwner(() => db.query(
      'update public.daily_logs set owner_id = $2 where id = $1', [id(2), otherOwner],
    )), { code: '42501' });
    assert.equal((await asOwner(() => db.query(
      'update public.daily_logs set owner_id = $2 where id = $1', [id(3), owner],
    ))).affectedRows, 0);
    assert.equal((await asOwner(() => db.query('delete from public.daily_logs where id = $1', [id(3)]))).affectedRows, 0);
    await db.exec('drop policy fixture_permissive_all on public.daily_logs');
  });

  await test('existing SECURITY INVOKER patch_record accepts owned and consistent legacy records only', async () => {
    const patch = async (n) => (await db.query(
      'select public.patch_record($1, $2, $3::jsonb) as patched',
      ['daily_logs', id(n), JSON.stringify({ fixture: true })],
    )).rows;
    for (const number of [1, 2]) {
      const [row] = await asOwner(() => patch(number));
      assert.equal(row.patched.id, id(number));
      assert.equal(row.patched.data.fixture, true);
      assert.equal(row.patched.data.retained, true);
    }
    for (const number of [3, 4]) assert.deepEqual(await asOwner(() => patch(number)), []);
  });

  await test('all entity DELETE policies preserve inaccessible records and allow current UUID and consistent legacy owners', async () => {
    for (const table of tables) {
      const result = await asOwner(() => db.query(
        `delete from public.${table} where id = any($1::uuid[]) returning id`,
        [[1, 2, 3, 4].map(id)],
      ));
      assert.deepEqual(result.rows.map((row) => row.id).sort(), [id(1), id(2)], table);
      assert.equal((await readRow(table, 3)).owner_id, otherOwner);
      assert.equal((await readRow(table, 4)).created_by, otherEmail);
    }
  });

  await test('service role keeps cross-owner CRUD and existing storage policy behavior remains in force', async () => {
    for (const table of tables) {
      await asRole('service_role', {}, async () => {
        assert.equal((await readRow(table, 3)).owner_id, otherOwner);
        assert.equal((await insert(table, 41, { ownerID: otherOwner })).affectedRows, 1);
        assert.equal((await db.query(`update public.${table} set data = '{"maintenance":true}' where id=$1`, [id(41)])).affectedRows, 1);
        assert.equal((await db.query(`delete from public.${table} where id=$1`, [id(41)])).affectedRows, 1);
      });
    }
    const listUploads = () => db.query('select name from storage.objects order by name');
    assert.deepEqual((await asRole('anon', {}, listUploads)).rows, [{ name: 'seed/path.txt' }]);
    const upload = (folder) => db.query(
      "insert into storage.objects (name, bucket_id) values ($1, 'uploads')",
      [`${folder}/report.txt`],
    );
    assert.equal((await asOwner(() => upload(owner))).affectedRows, 1);
    await assert.rejects(asOwner(() => upload(otherOwner)), { code: '42501' });
  });

  await test('dropping only the additive policies restores the exact baseline catalog without modifying records', async () => {
    const contents = () => Promise.all(tables.map(async (table) =>
      (await db.query(`select * from public.${table} order by id`)).rows,
    ));
    const before = await contents();
    await db.exec('begin');
    for (const table of tables) {
      await db.exec(`drop policy "entity ownership guard" on public.${table}`);
    }
    await db.exec('commit');
    assert.deepEqual(await policies(), baselinePolicies);
    assert.deepEqual(await rlsState(), baselineRLS);
    assert.deepEqual(await contents(), before);
    assert.equal((await asOwner(() => readRow('daily_logs', 3))).owner_id, otherOwner);
  });

  const report = {
    scope: 'Local PGlite PostgreSQL with synthetic identities and auth/storage role shims. No remote PostgREST or deployed policy acceptance.',
    tablesChecked: tables.length,
    passed: results.length,
    results,
  };
  if (process.env.OWNERSHIP_POLICY_RESULTS_PATH) {
    await writeFile(process.env.OWNERSHIP_POLICY_RESULTS_PATH, JSON.stringify(report, null, 2) + '\n');
  }
  console.log('SUMMARY', results.length, 'PostgreSQL/RLS groups passed across', tables.length, 'entity tables');
} finally {
  await db.close();
}

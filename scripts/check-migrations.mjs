// Applies every migration in supabase/migrations to Postgres-in-WASM and
// asserts the shape of what comes out.
//
//   cd scripts && npm install && npm run check
//
// This is not a substitute for applying them to the real project — PGlite has
// no auth schema and no storage schema, so both are stubbed below, and nothing
// here proves that PowerSync can actually replicate. What it does catch, in
// about ten seconds and without Docker, is the class of mistake that is
// expensive to find later: SQL that does not parse, a constraint that does not
// fire, a cascade that does not cascade, a trigger that was never attached, a
// table that was never added to the publication.
//
// Adding a table? Add a block of checks for it. The checks are the place where
// "what this schema promises" is written down executably.

import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const MIGRATIONS = path.join(here, '..', 'supabase', 'migrations');
const db = new PGlite();

let pass = 0;
let fail = 0;

const check = async (name, fn) => {
  try {
    await fn();
    console.log(`  ok    ${name}`);
    pass++;
  } catch (e) {
    console.log(`  FAIL  ${name}\n        ${e.message.split('\n')[0]}`);
    fail++;
  }
};
const expect = (cond, msg) => {
  if (!cond) throw new Error(msg);
};
const rejects = async (sql, params) => {
  try {
    await db.query(sql, params);
    return false;
  } catch {
    return true;
  }
};
const newUser = async () =>
  (await db.query(`insert into auth.users default values returning id`)).rows[0].id;

// Supabase-only objects PGlite does not ship. Enough for the DDL to apply and
// for the checks below to mean something.
await db.exec(`
  create schema if not exists auth;
  create schema if not exists storage;
  create table auth.users (
    id uuid primary key default gen_random_uuid(),
    email text,
    raw_user_meta_data jsonb not null default '{}'
  );
  create or replace function auth.uid() returns uuid language sql stable
    as $$ select current_setting('request.jwt.claim.sub', true)::uuid $$;
  create role authenticated;

  create table storage.buckets (
    id text primary key,
    name text not null,
    public boolean not null default false,
    file_size_limit bigint,
    allowed_mime_types text[]
  );
  create table storage.objects (
    id uuid primary key default gen_random_uuid(),
    bucket_id text references storage.buckets (id),
    name text not null,
    owner uuid
  );
  create or replace function storage.foldername(name text)
    returns text[] language sql immutable
    as $$ select string_to_array(name, '/') $$;
`);

const files = readdirSync(MIGRATIONS).filter((f) => f.endsWith('.sql')).sort();
for (const file of files) {
  const sql = readFileSync(path.join(MIGRATIONS, file), 'utf8');
  try {
    await db.exec(sql);
    console.log(`applied ${file}`);
  } catch (e) {
    console.log(`FAILED TO APPLY ${file}\n  ${e.message}`);
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// Conventions every synced table has to follow (CLAUDE.md, docs/PLAN.md §8)
// ---------------------------------------------------------------------------

const SYNCED = [
  'exercises', 'programs', 'mesocycles', 'templates', 'template_exercises',
  'sessions', 'session_exercises', 'sets', 'progression_state',
  'body_metrics', 'daily_activity', 'recovery_daily', 'progress_photos',
  'daily_rollup',
];

console.log('\nevery synced table:');

for (const table of SYNCED) {
  await check(`${table} carries user_id, soft-deletes, and has RLS`, async () => {
    const cols = (await db.query(
      `select column_name, is_nullable from information_schema.columns
       where table_schema='public' and table_name=$1`, [table])).rows;
    expect(cols.length > 0, 'table missing');

    const userId = cols.find((c) => c.column_name === 'user_id');
    expect(userId, 'no user_id column');
    // exercises is the one table with a shared library, so user_id is nullable.
    if (table !== 'exercises') {
      expect(userId.is_nullable === 'NO', 'user_id must be not null');
    }
    for (const c of ['id', 'created_at', 'updated_at', 'deleted_at']) {
      expect(cols.some((x) => x.column_name === c), `missing ${c}`);
    }

    const rls = (await db.query(
      `select relrowsecurity from pg_class where relname=$1`, [table])).rows[0];
    expect(rls?.relrowsecurity === true, 'RLS not enabled');

    const policies = (await db.query(
      `select policyname from pg_policies where tablename=$1`, [table])).rows;
    expect(policies.length >= 1, 'no policy');

    const trigger = (await db.query(
      `select tgname from pg_trigger t join pg_class c on c.oid = t.tgrelid
       where c.relname=$1 and tgname like '%set_updated_at'`, [table])).rows;
    expect(trigger.length === 1, 'no updated_at trigger');

    // Without this the table is in the app and in the stream config but never
    // reaches PowerSync — it would sync nothing, silently.
    const published = (await db.query(
      `select 1 from pg_publication_tables
       where pubname='powersync' and schemaname='public' and tablename=$1`,
      [table])).rows;
    expect(published.length === 1, 'not in the powersync publication');
  });
}

// ---------------------------------------------------------------------------
// progression_state (Phase 1)
// ---------------------------------------------------------------------------

console.log('\nprogression_state:');

await check('has the columns docs/PLAN.md §8 specifies', async () => {
  const cols = (await db.query(
    `select column_name from information_schema.columns
     where table_name='progression_state'`)).rows.map((x) => x.column_name);
  for (const c of ['exercise_id', 'model', 'next_load_kg', 'next_reps',
    'stall_count', 'best_e1rm_kg']) {
    expect(cols.includes(c), `missing ${c}`);
  }
});

await check('one live state row per exercise per user', async () => {
  const uid = await newUser();
  const ex = (await db.query(
    `insert into public.exercises (name) values ('Bench') returning id`)).rows[0].id;
  await db.query(
    `insert into public.progression_state (user_id, exercise_id) values ($1,$2)`,
    [uid, ex]);
  expect(
    await rejects(
      `insert into public.progression_state (user_id, exercise_id) values ($1,$2)`,
      [uid, ex]),
    'duplicate (user_id, exercise_id) was allowed');
});

await check('a soft-deleted row does not block the next one', async () => {
  // The 23505 bug: sync-streams hides deleted rows from the device, so the app
  // writes a fresh uuid and Postgres used to reject it.
  const uid = await newUser();
  const ex = (await db.query(
    `insert into public.exercises (name) values ('Squat') returning id`)).rows[0].id;
  await db.query(
    `insert into public.progression_state (user_id, exercise_id, deleted_at)
     values ($1,$2,now())`, [uid, ex]);
  await db.query(
    `insert into public.progression_state (user_id, exercise_id) values ($1,$2)`,
    [uid, ex]);
});

await check('state can reference a seeded exercise (user_id null)', async () => {
  const uid = await newUser();
  const seeded = (await db.query(
    `select id from public.exercises where user_id is null limit 1`)).rows[0];
  expect(seeded, 'no seeded exercise found');
  await db.query(
    `insert into public.progression_state (user_id, exercise_id) values ($1,$2)`,
    [uid, seeded.id]);
});

await check('rejects an unknown progression model', async () => {
  const uid = await newUser();
  const ex = (await db.query(
    `insert into public.exercises (name) values ('Row') returning id`)).rows[0].id;
  expect(
    await rejects(
      `insert into public.progression_state (user_id, exercise_id, model)
       values ($1,$2,'nonsense')`, [uid, ex]),
    'check constraint on model did not fire');
});

await check('deleting the exercise takes its state with it', async () => {
  const uid = await newUser();
  const ex = (await db.query(
    `insert into public.exercises (name) values ('Fly') returning id`)).rows[0].id;
  await db.query(
    `insert into public.progression_state (user_id, exercise_id) values ($1,$2)`,
    [uid, ex]);
  await db.query(`delete from public.exercises where id=$1`, [ex]);
  const left = (await db.query(
    `select 1 from public.progression_state where exercise_id=$1`, [ex])).rows;
  expect(left.length === 0, 'orphan state left behind');
});

// ---------------------------------------------------------------------------
// Phase 2 — Body & Move
// ---------------------------------------------------------------------------

const DAY_KEYED = {
  body_metrics: 'measured_on',
  daily_activity: 'activity_on',
  recovery_daily: 'recovered_on',
  daily_rollup: 'rollup_on',
};

console.log('\nbody & move — one row per day:');

for (const [table, day] of Object.entries(DAY_KEYED)) {
  await check(`${table} keeps one live row per day`, async () => {
    const uid = await newUser();
    await db.query(
      `insert into public.${table} (user_id, ${day}) values ($1,'2026-09-12')`, [uid]);
    expect(
      await rejects(
        `insert into public.${table} (user_id, ${day}) values ($1,'2026-09-12')`,
        [uid]),
      'a second row for the same day was allowed');
  });

  await check(`${table} lets a deleted day be logged again`, async () => {
    const uid = await newUser();
    await db.query(
      `insert into public.${table} (user_id, ${day}, deleted_at)
       values ($1,'2026-09-13',now())`, [uid]);
    await db.query(
      `insert into public.${table} (user_id, ${day}) values ($1,'2026-09-13')`, [uid]);
  });

  await check(`${table} lets two users log the same day`, async () => {
    const a = await newUser();
    const b = await newUser();
    await db.query(
      `insert into public.${table} (user_id, ${day}) values ($1,'2026-09-14')`, [a]);
    await db.query(
      `insert into public.${table} (user_id, ${day}) values ($1,'2026-09-14')`, [b]);
  });

  await check(`${table} goes with the user`, async () => {
    const uid = await newUser();
    await db.query(
      `insert into public.${table} (user_id, ${day}) values ($1,'2026-09-15')`, [uid]);
    await db.query(`delete from auth.users where id=$1`, [uid]);
    const left = (await db.query(
      `select 1 from public.${table} where user_id=$1`, [uid])).rows;
    expect(left.length === 0, 'rows survived the account being deleted');
  });
}

console.log('\nbody & move — the numbers have to be plausible:');

await check('body_metrics rejects a weight off the scale', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.body_metrics (user_id, measured_on, weight_kg)
       values ($1,'2026-09-16',900)`, [uid]),
    'accepted 900 kg');
  expect(
    await rejects(
      `insert into public.body_metrics (user_id, measured_on, weight_kg)
       values ($1,'2026-09-16',-5)`, [uid]),
    'accepted a negative weight');
});

await check('body_metrics rejects an unknown source', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.body_metrics (user_id, measured_on, source)
       values ($1,'2026-09-17','guessed')`, [uid]),
    'accepted an unknown source');
});

await check('recovery_daily holds a check-in only on the 1-5 scale', async () => {
  const uid = await newUser();
  await db.query(
    `insert into public.recovery_daily
       (user_id, recovered_on, sleep_quality, soreness, stress, energy, readiness)
     values ($1,'2026-09-18',4,2,2,4,72)`, [uid]);
  expect(
    await rejects(
      `insert into public.recovery_daily (user_id, recovered_on, energy)
       values ($1,'2026-09-19',7)`, [uid]),
    'accepted an answer outside 1-5');
  expect(
    await rejects(
      `insert into public.recovery_daily (user_id, recovered_on, readiness)
       values ($1,'2026-09-20',140)`, [uid]),
    'accepted a readiness score above 100');
});

await check('daily_activity rejects an impossible step count', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.daily_activity (user_id, activity_on, steps)
       values ($1,'2026-09-21',-1)`, [uid]),
    'accepted negative steps');
});

await check('progress_photos needs somewhere for the file to live', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.progress_photos (user_id, taken_on) values ($1,'2026-09-22')`,
      [uid]),
    'accepted a photo row with no storage_path');
  await db.query(
    `insert into public.progress_photos (user_id, taken_on, pose, storage_path)
     values ($1,'2026-09-22','side',$2)`, [uid, `${uid}/abc.jpg`]);
  expect(
    await rejects(
      `insert into public.progress_photos (user_id, taken_on, pose, storage_path)
       values ($1,'2026-09-23','sideways',$2)`, [uid, `${uid}/def.jpg`]),
    'accepted an unknown pose');
});

await check('progress_photos allows several poses on one day', async () => {
  // Deliberately not one-per-day: front, side and back are the same session.
  const uid = await newUser();
  for (const pose of ['front', 'side', 'back']) {
    await db.query(
      `insert into public.progress_photos (user_id, taken_on, pose, storage_path)
       values ($1,'2026-09-24',$2,$3)`, [uid, pose, `${uid}/${pose}.jpg`]);
  }
});

await check('the photo bucket is private and typed', async () => {
  const bucket = (await db.query(
    `select public, allowed_mime_types from storage.buckets where id='progress-photos'`
  )).rows[0];
  expect(bucket, 'bucket not created');
  expect(bucket.public === false, 'bucket is public');
  expect(bucket.allowed_mime_types?.includes('image/jpeg'), 'jpeg not allowed');
  const policies = (await db.query(
    `select policyname from pg_policies
     where schemaname='storage' and tablename='objects'`)).rows;
  expect(policies.length >= 4, 'expected read/insert/update/delete policies');
});

await check('daily_rollup has a column for every part of a day', async () => {
  const cols = (await db.query(
    `select column_name from information_schema.columns
     where table_name='daily_rollup'`)).rows.map((x) => x.column_name);
  for (const c of ['trend_weight_kg', 'intake_kcal', 'protein_g', 'tdee_est',
    'steps', 'hard_sets', 'volume_kg', 'sleep_minutes', 'readiness',
    'fatigue_score', 'phase']) {
    expect(cols.includes(c), `missing ${c}`);
  }
});

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);

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
  'foods', 'recipes', 'recipe_items', 'meals', 'meal_items',
  'nutrition_targets', 'prep_batches',
  'coach_threads', 'coach_messages', 'coach_memories', 'ai_proposals',
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

// ---------------------------------------------------------------------------
// Phase 3 — Fuel
// ---------------------------------------------------------------------------

console.log('\nfuel:');

/// A user with one food, ready to hang meals off.
const userWithFood = async (name = 'Oats') => {
  const uid = await newUser();
  const food = (await db.query(
    `insert into public.foods (user_id, name, kcal_per_100, protein_per_100)
     values ($1,$2,379,13.2) returning id`, [uid, name])).rows[0].id;
  return { uid, food };
};

await check('a food belongs to exactly one lifter', async () => {
  const cols = (await db.query(
    `select is_nullable from information_schema.columns
     where table_name='foods' and column_name='user_id'`)).rows[0];
  // Unlike exercises, there is no shared library: the real food databases are
  // too big to sync, so foods are per-lifter copies and children can use the
  // composite key safely.
  expect(cols.is_nullable === 'NO', 'foods.user_id must be not null');
});

await check('a meal item cannot borrow another lifter food', async () => {
  const mine = await userWithFood();
  const theirs = await userWithFood('Rice');
  const meal = (await db.query(
    `insert into public.meals (user_id, meal_on) values ($1,'2026-09-13')
     returning id`, [mine.uid])).rows[0].id;
  expect(
    await rejects(
      `insert into public.meal_items (user_id, meal_id, food_id, quantity_g, kcal)
       values ($1,$2,$3,100,379)`, [mine.uid, meal, theirs.food]),
    'a meal item pointed at another user food');
});

await check('a meal item is a food or a recipe, never both or neither', async () => {
  const { uid, food } = await userWithFood();
  const meal = (await db.query(
    `insert into public.meals (user_id, meal_on) values ($1,'2026-09-13')
     returning id`, [uid])).rows[0].id;
  const recipe = (await db.query(
    `insert into public.recipes (user_id, name) values ($1,'Chilli') returning id`,
    [uid])).rows[0].id;

  await db.query(
    `insert into public.meal_items (user_id, meal_id, food_id, quantity_g, kcal)
     values ($1,$2,$3,100,379)`, [uid, meal, food]);
  await db.query(
    `insert into public.meal_items (user_id, meal_id, recipe_id, quantity_g, kcal)
     values ($1,$2,$3,300,450)`, [uid, meal, recipe]);

  expect(
    await rejects(
      `insert into public.meal_items (user_id, meal_id, quantity_g, kcal)
       values ($1,$2,100,379)`, [uid, meal]),
    'accepted an item that was neither a food nor a recipe');
  expect(
    await rejects(
      `insert into public.meal_items
         (user_id, meal_id, food_id, recipe_id, quantity_g, kcal)
       values ($1,$2,$3,$4,100,379)`, [uid, meal, food, recipe]),
    'accepted an item that was both');
});

await check('deleting a meal takes its items with it', async () => {
  const { uid, food } = await userWithFood();
  const meal = (await db.query(
    `insert into public.meals (user_id, meal_on) values ($1,'2026-09-13')
     returning id`, [uid])).rows[0].id;
  await db.query(
    `insert into public.meal_items (user_id, meal_id, food_id, quantity_g, kcal)
     values ($1,$2,$3,100,379)`, [uid, meal, food]);
  await db.query(`delete from public.meals where id=$1`, [meal]);
  const left = (await db.query(
    `select 1 from public.meal_items where meal_id=$1`, [meal])).rows;
  expect(left.length === 0, 'orphan meal items left behind');
});

await check('a food in use cannot be hard-deleted out from under a recipe', async () => {
  const { uid, food } = await userWithFood();
  const recipe = (await db.query(
    `insert into public.recipes (user_id, name) values ($1,'Porridge') returning id`,
    [uid])).rows[0].id;
  await db.query(
    `insert into public.recipe_items (user_id, recipe_id, food_id, quantity_g)
     values ($1,$2,$3,80)`, [uid, recipe, food]);
  expect(
    await rejects(`delete from public.foods where id=$1`, [food]),
    'a recipe was left pointing at nothing');
});

await check('a food that has been eaten cannot be hard-deleted', async () => {
  // Removing a food from the list is a soft delete. Hard-deleting it would
  // either take the meal with it or leave an item that is neither a food nor a
  // recipe, and a logged day must stay exactly as it was logged.
  const { uid, food } = await userWithFood();
  const meal = (await db.query(
    `insert into public.meals (user_id, meal_on) values ($1,'2026-09-13')
     returning id`, [uid])).rows[0].id;
  await db.query(
    `insert into public.meal_items (user_id, meal_id, food_id, quantity_g, kcal, protein_g)
     values ($1,$2,$3,100,379,13.2)`, [uid, meal, food]);
  expect(
    await rejects(`delete from public.foods where id=$1`, [food]),
    'a logged meal lost the food underneath it');

  // Soft-deleting it leaves the log untouched.
  await db.query(
    `update public.foods set deleted_at = now() where id=$1`, [food]);
  const item = (await db.query(
    `select kcal, protein_g from public.meal_items where meal_id=$1`,
    [meal])).rows[0];
  expect(Number(item.kcal) === 379, 'the logged calories were lost');
});

await check('one live food per barcode per lifter', async () => {
  const uid = await newUser();
  await db.query(
    `insert into public.foods (user_id, name, kcal_per_100, barcode)
     values ($1,'Beans',78,'5000157024671')`, [uid]);
  expect(
    await rejects(
      `insert into public.foods (user_id, name, kcal_per_100, barcode)
       values ($1,'Beans again',78,'5000157024671')`, [uid]),
    'the same barcode was stored twice');

  // Two lifters can each have their own copy of the same tin.
  const other = await newUser();
  await db.query(
    `insert into public.foods (user_id, name, kcal_per_100, barcode)
     values ($1,'Beans',78,'5000157024671')`, [other]);
});

await check('a deleted food frees its barcode again', async () => {
  const uid = await newUser();
  await db.query(
    `insert into public.foods (user_id, name, kcal_per_100, barcode, deleted_at)
     values ($1,'Old',78,'5000157024999',now())`, [uid]);
  await db.query(
    `insert into public.foods (user_id, name, kcal_per_100, barcode)
     values ($1,'New',78,'5000157024999')`, [uid]);
});

await check('a barcode has to look like a barcode', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.foods (user_id, name, kcal_per_100, barcode)
       values ($1,'Nonsense',78,'not-a-barcode')`, [uid]),
    'accepted a barcode that was not digits');
});

await check('nutrition has to be physically possible', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.foods (user_id, name, kcal_per_100) values ($1,'Dense',1200)`,
      [uid]),
    'accepted more kcal than a gram of fat can carry');
  expect(
    await rejects(
      `insert into public.foods (user_id, name, kcal_per_100, protein_per_100)
       values ($1,'Impossible',400,150)`, [uid]),
    'accepted more than 100 g of protein per 100 g');
});

await check('a food is measured by weight or by volume, not by vibes', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.foods (user_id, name, kcal_per_100, basis)
       values ($1,'Soup',40,'cups')`, [uid]),
    'accepted an unknown basis');
});

await check('one live target per start date', async () => {
  const uid = await newUser();
  const insert = `insert into public.nutrition_targets
      (user_id, effective_from, kcal, protein_g, carb_g, fat_g)
    values ($1,'2026-09-13',2400,180,220,70)`;
  await db.query(insert, [uid]);
  expect(await rejects(insert, [uid]), 'two live targets started the same day');
});

await check('targets keep their history rather than overwriting', async () => {
  const uid = await newUser();
  for (const [from, kcal] of [['2026-08-01', 2600], ['2026-09-01', 2400]]) {
    await db.query(
      `insert into public.nutrition_targets
         (user_id, effective_from, kcal, protein_g, carb_g, fat_g)
       values ($1,$2,$3,180,220,70)`, [uid, from, kcal]);
  }
  const rows = (await db.query(
    `select kcal from public.nutrition_targets
     where user_id=$1 order by effective_from desc`, [uid])).rows;
  expect(rows.length === 2, 'the older target was lost');
  expect(Number(rows[0].kcal) === 2400, 'the newest target is not first');
});

await check('a target has to be survivable', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.nutrition_targets
         (user_id, effective_from, kcal, protein_g, carb_g, fat_g)
       values ($1,'2026-09-13',400,180,220,70)`, [uid]),
    'accepted a starvation target');
});

await check('the carb shift is a share, not a multiplier', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.nutrition_targets
         (user_id, effective_from, kcal, protein_g, carb_g, fat_g,
          training_day_carb_shift_pct)
       values ($1,'2026-09-13',2400,180,220,70,90)`, [uid]),
    'accepted a 90% carb shift');
});

await check('meals go with the lifter', async () => {
  // Deliberately exercises every "no action" edge at once: deleting the account
  // has to take the food, the recipe built from it and the meal that ate both,
  // all in one statement, without any of them blocking the others.
  const { uid, food } = await userWithFood();
  const recipe = (await db.query(
    `insert into public.recipes (user_id, name) values ($1,'Overnight oats')
     returning id`, [uid])).rows[0].id;
  await db.query(
    `insert into public.recipe_items (user_id, recipe_id, food_id, quantity_g)
     values ($1,$2,$3,80)`, [uid, recipe, food]);
  const meal = (await db.query(
    `insert into public.meals (user_id, meal_on) values ($1,'2026-09-13')
     returning id`, [uid])).rows[0].id;
  await db.query(
    `insert into public.meal_items (user_id, meal_id, food_id, quantity_g, kcal)
     values ($1,$2,$3,100,379)`, [uid, meal, food]);
  await db.query(
    `insert into public.nutrition_targets
       (user_id, effective_from, kcal, protein_g, carb_g, fat_g)
     values ($1,'2026-09-13',2400,180,220,70)`, [uid]);

  await db.query(`delete from auth.users where id=$1`, [uid]);
  for (const table of ['foods', 'recipes', 'recipe_items', 'meals',
    'meal_items', 'nutrition_targets', 'prep_batches']) {
    const left = (await db.query(
      `select 1 from public.${table} where user_id=$1`, [uid])).rows;
    expect(left.length === 0, `${table} survived the account being deleted`);
  }
});


// ---------------------------------------------------------------------------
// meal prep
// ---------------------------------------------------------------------------

console.log('\nmeal prep:');

const userWithBatch = async () => {
  const { uid, food } = await userWithFood();
  const recipe = (await db.query(
    `insert into public.recipes (user_id, name, servings) values ($1,'Chilli',4)
     returning id`, [uid])).rows[0].id;
  await db.query(
    `insert into public.recipe_items (user_id, recipe_id, food_id, quantity_g)
     values ($1,$2,$3,600)`, [uid, recipe, food]);
  const batch = (await db.query(
    `insert into public.prep_batches
       (user_id, recipe_id, cooked_on, servings_made, cooked_weight_g, use_by)
     values ($1,$2,'2026-09-14',4,1330,'2026-09-18') returning id`,
    [uid, recipe])).rows[0].id;
  return { uid, food, recipe, batch };
};

await check('a batch cannot borrow a recipe belonging to somebody else', async () => {
  const { uid, recipe } = await userWithBatch();
  const other = await newUser();
  expect(
    await rejects(
      `insert into public.prep_batches
         (user_id, recipe_id, cooked_on, servings_made)
       values ($1,$2,'2026-09-14',4)`, [other, recipe]),
    'attached a batch to a recipe belonging to somebody else');
});

await check('a portion points at the batch it came out of', async () => {
  const { uid, recipe, batch } = await userWithBatch();
  const meal = (await db.query(
    `insert into public.meals (user_id, meal_on) values ($1,'2026-09-15')
     returning id`, [uid])).rows[0].id;
  await db.query(
    `insert into public.meal_items
       (user_id, meal_id, recipe_id, prep_batch_id, quantity_g, kcal, source)
     values ($1,$2,$3,$4,332,512,'prep')`, [uid, meal, recipe, batch]);

  // Servings remaining is derived, never stored: this is the query that does
  // it, and the reason no column counts down.
  const left = (await db.query(
    `select b.servings_made
          - coalesce(sum(i.quantity_g) / nullif(b.cooked_weight_g,0)
                     * b.servings_made, 0) as remaining
       from public.prep_batches b
       left join public.meal_items i
         on i.prep_batch_id = b.id and i.deleted_at is null
      where b.id = $1
      group by b.id`, [batch])).rows[0];
  expect(Number(left.remaining) > 2.9 && Number(left.remaining) < 3.1,
    `one portion of four should leave three, got ${left.remaining}`);
});

await check('a portion from a batch has to be a portion of its recipe', async () => {
  const { uid, food, batch } = await userWithBatch();
  const meal = (await db.query(
    `insert into public.meals (user_id, meal_on) values ($1,'2026-09-15')
     returning id`, [uid])).rows[0].id;
  // A food and a batch: the item would claim to be prepped chilli and a
  // weighed lump of chicken at once.
  expect(
    await rejects(
      `insert into public.meal_items
         (user_id, meal_id, food_id, prep_batch_id, quantity_g, kcal)
       values ($1,$2,$3,$4,100,379)`, [uid, meal, food, batch]),
    'accepted a batch portion that was not a recipe portion');
});

await check("'prep' is an allowed source", async () => {
  const { uid, recipe, batch } = await userWithBatch();
  const meal = (await db.query(
    `insert into public.meals (user_id, meal_on) values ($1,'2026-09-15')
     returning id`, [uid])).rows[0].id;
  await db.query(
    `insert into public.meal_items
       (user_id, meal_id, recipe_id, prep_batch_id, quantity_g, kcal, source)
     values ($1,$2,$3,$4,332,512,'prep')`, [uid, meal, recipe, batch]);
  expect(
    await rejects(
      `insert into public.meal_items
         (user_id, meal_id, recipe_id, quantity_g, kcal, source)
       values ($1,$2,$3,100,200,'telepathy')`, [uid, meal, recipe]),
    'the source list stopped being a list');
});

await check('deleting a recipe takes its batches with it', async () => {
  const { recipe, batch } = await userWithBatch();
  await db.query(`delete from public.recipes where id=$1`, [recipe]);
  const left = (await db.query(
    `select 1 from public.prep_batches where id=$1`, [batch])).rows;
  expect(left.length === 0, 'orphan batch left behind');
});

await check('a batch cannot claim more servings than a pot holds', async () => {
  const { uid, recipe } = await userWithBatch();
  expect(
    await rejects(
      `insert into public.prep_batches
         (user_id, recipe_id, cooked_on, servings_made)
       values ($1,$2,'2026-09-14',0)`, [uid, recipe]),
    'accepted a cook that made nothing');
});


// ---------------------------------------------------------------------------
// coach (Phase 4)
// ---------------------------------------------------------------------------

console.log('\ncoach:');

const userWithThread = async () => {
  const uid = await newUser();
  const thread = (await db.query(
    `insert into public.coach_threads (user_id) values ($1) returning id`,
    [uid])).rows[0].id;
  return { uid, thread };
};

await check('a thread only holds the kinds of conversation that exist', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.coach_threads (user_id, kind) values ($1,'gossip')`,
      [uid]),
    'accepted an unknown thread kind');
});

await check('two messages cannot take the same place in a thread', async () => {
  // The device generates both the turn and the reply, often in the same
  // millisecond, so created_at cannot order them and position has to.
  const { uid, thread } = await userWithThread();
  await db.query(
    `insert into public.coach_messages (user_id, thread_id, position, role)
     values ($1,$2,0,'user')`, [uid, thread]);
  expect(
    await rejects(
      `insert into public.coach_messages (user_id, thread_id, position, role)
       values ($1,$2,0,'assistant')`, [uid, thread]),
    'accepted two messages at position 0');
});

await check('a deleted message frees its place', async () => {
  // The index is partial, so a soft-deleted turn must not block the one that
  // replaces it — the same rule the day-keyed tables follow.
  const { uid, thread } = await userWithThread();
  const first = (await db.query(
    `insert into public.coach_messages (user_id, thread_id, position, role)
     values ($1,$2,0,'user') returning id`, [uid, thread])).rows[0].id;
  await db.query(
    `update public.coach_messages set deleted_at=now() where id=$1`, [first]);
  await db.query(
    `insert into public.coach_messages (user_id, thread_id, position, role)
     values ($1,$2,0,'user')`, [uid, thread]);
});

await check('a message cannot be attached to another lifter\'s thread', async () => {
  const { thread } = await userWithThread();
  const other = await newUser();
  expect(
    await rejects(
      `insert into public.coach_messages (user_id, thread_id, position, role)
       values ($1,$2,0,'user')`, [other, thread]),
    'attached a message to a thread belonging to someone else');
});

await check('deleting a thread takes its messages', async () => {
  const { uid, thread } = await userWithThread();
  await db.query(
    `insert into public.coach_messages (user_id, thread_id, position, role)
     values ($1,$2,0,'user')`, [uid, thread]);
  await db.query(`delete from public.coach_threads where id=$1`, [thread]);
  const left = (await db.query(
    `select 1 from public.coach_messages where thread_id=$1`, [thread])).rows;
  expect(left.length === 0, 'messages outlived their thread');
});

await check('a memory outlives the conversation that produced it', async () => {
  // "Your left shoulder complains on overhead press" does not stop being true
  // because the thread it was said in was deleted.
  const { uid, thread } = await userWithThread();
  await db.query(
    `insert into public.coach_memories (user_id, thread_id, content)
     values ($1,$2,'Left shoulder complains on overhead press')`, [uid, thread]);
  await db.query(`delete from public.coach_threads where id=$1`, [thread]);
  const kept = (await db.query(
    `select thread_id from public.coach_memories where user_id=$1`, [uid])).rows;
  expect(kept.length === 1, 'the memory went with the thread');
  expect(kept[0].thread_id === null, 'the memory still points at a dead thread');
});

await check('a proposal outlives the conversation that produced it', async () => {
  const { uid, thread } = await userWithThread();
  await db.query(
    `insert into public.ai_proposals (user_id, thread_id, kind, payload)
     values ($1,$2,'deload','{}'::jsonb)`, [uid, thread]);
  await db.query(`delete from public.coach_threads where id=$1`, [thread]);
  const kept = (await db.query(
    `select thread_id from public.ai_proposals where user_id=$1`, [uid])).rows;
  expect(kept.length === 1, 'the proposal went with the thread');
  expect(kept[0].thread_id === null, 'the proposal still points at a dead thread');
});

await check('an empty memory is not a memory', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.coach_memories (user_id, content) values ($1,'')`,
      [uid]),
    'accepted an empty memory');
});

await check('a proposal starts unanswered and unvalidated', async () => {
  const uid = await newUser();
  const row = (await db.query(
    `insert into public.ai_proposals (user_id, kind, payload)
     values ($1,'deload','{"weeks":1}'::jsonb)
     returning status, validated, responded_at`, [uid])).rows[0];
  expect(row.status === 'pending', 'did not start pending');
  expect(row.validated === false, 'started validated');
  expect(row.responded_at === null, 'started answered');
});

await check('an answered proposal has to say when', async () => {
  // The proposals inbox reads this invariant, so it is enforced here rather
  // than trusted to whoever writes the row.
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.ai_proposals (user_id, kind, payload, status)
       values ($1,'deload','{}'::jsonb,'accepted')`, [uid]),
    'accepted an answer with no answered-at');
});

await check('an unanswered proposal cannot claim to have been answered', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.ai_proposals (user_id, kind, payload, responded_at)
       values ($1,'deload','{}'::jsonb, now())`, [uid]),
    'a pending proposal carried a responded_at');
});

await check('only a decline carries a reason', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.ai_proposals
         (user_id, kind, payload, status, responded_at, decline_reason)
       values ($1,'deload','{}'::jsonb,'accepted', now(), 'too soon')`, [uid]),
    'an accepted proposal carried a decline reason');
  // And a real decline does.
  await db.query(
    `insert into public.ai_proposals
       (user_id, kind, payload, status, responded_at, decline_reason)
     values ($1,'deload','{}'::jsonb,'declined', now(), 'Competition in 2 weeks')`,
    [uid]);
});

await check('the coach cannot propose something nobody can apply', async () => {
  const uid = await newUser();
  expect(
    await rejects(
      `insert into public.ai_proposals (user_id, kind, payload)
       values ($1,'buy_supplements','{}'::jsonb)`, [uid]),
    'accepted a proposal kind the engine has no way to apply');
});

await check('the coach goes with the lifter', async () => {
  const { uid, thread } = await userWithThread();
  await db.query(
    `insert into public.coach_messages (user_id, thread_id, position, role)
     values ($1,$2,0,'user')`, [uid, thread]);
  await db.query(
    `insert into public.coach_memories (user_id, content) values ($1,'Travels often')`,
    [uid]);
  await db.query(
    `insert into public.ai_proposals (user_id, kind, payload)
     values ($1,'targets','{"kcal":2400}'::jsonb)`, [uid]);

  await db.query(`delete from auth.users where id=$1`, [uid]);
  for (const table of ['coach_threads', 'coach_messages', 'coach_memories',
    'ai_proposals']) {
    const left = (await db.query(
      `select 1 from public.${table} where user_id=$1`, [uid])).rows;
    expect(left.length === 0, `${table} survived the account being deleted`);
  }
});

console.log(`
${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);

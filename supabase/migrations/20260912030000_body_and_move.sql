-- Phase 2 (Body & Move): what the scale, the tape, the watch and the lifter say.
--
-- Four tables of evidence plus one of arithmetic:
--
--   body_metrics    the scale and the tape measure
--   daily_activity  steps and active energy, imported from Health Connect
--   recovery_daily  last night, plus the ten-second morning check-in
--   progress_photos private photos, the file itself in Storage
--   daily_rollup    one row per day with everything already joined
--
-- All five are keyed one row per calendar day per user. A day is the unit the
-- whole pillar works in: trend weight, step goals, readiness and the Today
-- dashboard all ask "what about this day", and a table shaped that way answers
-- it without a group-by. That uniqueness is enforced by a partial index which
-- ignores soft-deleted rows, because sync-streams filters those out — a deleted
-- row is gone from the device but still occupies its slot in Postgres, and a
-- plain unique constraint would reject the next write with 23505 while the
-- connector discarded it silently. (See 20260912020000 for the bug this avoids;
-- it is exactly the same shape.)
--
-- measured_on and its siblings are `date`, not `timestamptz`: they are calendar
-- days in the lifter's own timezone, which lives in profiles. Storing an
-- instant would make "Tuesday" depend on where they were standing.

-- ---------------------------------------------------------------------------
-- body_metrics: weight, body fat, tape measurements
-- ---------------------------------------------------------------------------

create table public.body_metrics (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  measured_on    date not null,
  weight_kg      double precision check (weight_kg between 20 and 500),
  body_fat_pct   double precision check (body_fat_pct between 1 and 70),
  neck_cm        double precision check (neck_cm between 10 and 100),
  shoulders_cm   double precision check (shoulders_cm between 50 and 250),
  chest_cm       double precision check (chest_cm between 40 and 250),
  waist_cm       double precision check (waist_cm between 30 and 250),
  hips_cm        double precision check (hips_cm between 30 and 250),
  thigh_cm       double precision check (thigh_cm between 20 and 150),
  calf_cm        double precision check (calf_cm between 10 and 100),
  arm_cm         double precision check (arm_cm between 10 and 100),
  forearm_cm     double precision check (forearm_cm between 10 and 100),
  -- Where the number came from. 'manual' is the lifter typing it in, 'health'
  -- is an import — and an import must never overwrite a typed-in value.
  source         text not null default 'manual'
                 check (source in ('manual', 'health')),
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  unique (id, user_id)
);

create unique index body_metrics_one_per_day
  on public.body_metrics (user_id, measured_on)
  where deleted_at is null;

create index body_metrics_user_day_idx
  on public.body_metrics (user_id, measured_on desc);

-- ---------------------------------------------------------------------------
-- daily_activity: steps and active energy, from Health Connect
-- ---------------------------------------------------------------------------

create table public.daily_activity (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null default auth.uid() references auth.users (id) on delete cascade,
  activity_on       date not null,
  steps             integer check (steps between 0 and 200000),
  active_kcal       double precision check (active_kcal between 0 and 20000),
  -- What Health thinks the body burned at rest. The engine prefers its own
  -- TDEE estimate (Phase 3) and keeps this only to compare against.
  resting_kcal      double precision check (resting_kcal between 0 and 10000),
  distance_m        double precision check (distance_m between 0 and 500000),
  floors            integer check (floors between 0 and 5000),
  exercise_minutes  integer check (exercise_minutes between 0 and 1440),
  source            text not null default 'health'
                    check (source in ('manual', 'health')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  unique (id, user_id)
);

create unique index daily_activity_one_per_day
  on public.daily_activity (user_id, activity_on)
  where deleted_at is null;

create index daily_activity_user_day_idx
  on public.daily_activity (user_id, activity_on desc);

-- ---------------------------------------------------------------------------
-- recovery_daily: last night, and this morning
-- ---------------------------------------------------------------------------

create table public.recovery_daily (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  recovered_on   date not null,

  -- Measured, where there is a watch to measure it.
  sleep_minutes  integer check (sleep_minutes between 0 and 1440),
  hrv_ms         double precision check (hrv_ms between 1 and 500),
  resting_hr     double precision check (resting_hr between 20 and 150),

  -- The morning check-in: four taps, 1-5. soreness and stress run the other way
  -- round (5 is the bad end); packages/engine/lib/src/readiness.dart is the one
  -- place that knows which way each of them points.
  sleep_quality  smallint check (sleep_quality between 1 and 5),
  soreness       smallint check (soreness between 1 and 5),
  stress         smallint check (stress between 1 and 5),
  energy         smallint check (energy between 1 and 5),
  checked_in_at  timestamptz,

  -- What the engine made of all of the above, 0-100. Stored rather than
  -- recomputed on read, so the coach sees the score the lifter actually saw and
  -- it survives a later change to the formula.
  readiness      smallint check (readiness between 0 and 100),
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  unique (id, user_id)
);

create unique index recovery_daily_one_per_day
  on public.recovery_daily (user_id, recovered_on)
  where deleted_at is null;

create index recovery_daily_user_day_idx
  on public.recovery_daily (user_id, recovered_on desc);

-- ---------------------------------------------------------------------------
-- progress_photos: the row syncs, the image does not
-- ---------------------------------------------------------------------------

create table public.progress_photos (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
  taken_on     date not null,
  pose         text not null default 'front'
               check (pose in ('front', 'side', 'back', 'other')),
  -- Object key in the private progress-photos bucket, always prefixed with the
  -- owner's uuid — the storage policies below depend on that shape.
  storage_path text not null check (length(storage_path) between 1 and 400),
  -- Denormalised so the compare view can label two photos without a join.
  weight_kg    double precision check (weight_kg between 20 and 500),
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  unique (id, user_id)
);

create index progress_photos_user_day_idx
  on public.progress_photos (user_id, taken_on desc);

-- ---------------------------------------------------------------------------
-- daily_rollup: the day, already joined
-- ---------------------------------------------------------------------------

create table public.daily_rollup (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  rollup_on       date not null,

  -- Body & Move (Phase 2).
  trend_weight_kg double precision check (trend_weight_kg between 20 and 500),
  weight_kg       double precision check (weight_kg between 20 and 500),
  steps           integer check (steps between 0 and 200000),
  sleep_minutes   integer check (sleep_minutes between 0 and 1440),
  readiness       smallint check (readiness between 0 and 100),
  hard_sets       smallint check (hard_sets between 0 and 200),
  volume_kg       double precision check (volume_kg >= 0),

  -- Fuel (Phase 3). The columns exist so the shape of a day is settled now;
  -- nothing writes them yet.
  intake_kcal     integer check (intake_kcal between 0 and 20000),
  protein_g       double precision check (protein_g between 0 and 1000),
  tdee_est        integer check (tdee_est between 0 and 20000),

  -- Engine v2 (Phase 5).
  fatigue_score   smallint check (fatigue_score between 0 and 100),

  phase           text check (phase in ('cut', 'maintain', 'bulk')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  unique (id, user_id)
);

create unique index daily_rollup_one_per_day
  on public.daily_rollup (user_id, rollup_on)
  where deleted_at is null;

create index daily_rollup_user_day_idx
  on public.daily_rollup (user_id, rollup_on desc);

-- ---------------------------------------------------------------------------
-- updated_at, RLS, grants, replication
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['body_metrics', 'daily_activity', 'recovery_daily',
                           'progress_photos', 'daily_rollup']
  loop
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.set_updated_at()',
      t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for all to authenticated '
      'using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)',
      t || ': owner only', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('alter publication powersync add table public.%I', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- progress-photos bucket: private, and reachable only by the lifter in it
-- ---------------------------------------------------------------------------
--
-- Nobody else gets a URL to these. The object key is <user_id>/<uuid>.jpg and
-- every policy checks that first segment against the caller, so a leaked row id
-- buys nothing on its own.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('progress-photos', 'progress-photos', false, 15728640,
        array['image/jpeg', 'image/png', 'image/heic', 'image/webp'])
on conflict (id) do nothing;

create policy "progress photos: owner can read" on storage.objects
  for select to authenticated
  using (bucket_id = 'progress-photos'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "progress photos: owner can upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'progress-photos'
              and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "progress photos: owner can replace" on storage.objects
  for update to authenticated
  using (bucket_id = 'progress-photos'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "progress photos: owner can delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'progress-photos'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

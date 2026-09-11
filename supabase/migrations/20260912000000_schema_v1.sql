-- Overload schema v1 (Phase 0): profiles + training core.
--
-- Conventions (see docs/PLAN.md §8):
--   * ids are uuid, generated on the device (UUIDv7) so rows can be created offline.
--   * every user-owned row carries user_id; RLS limits every query, including the
--     Coach API's, to auth.uid().
--   * child tables use composite foreign keys (parent_id, user_id) so a row can
--     only ever point at a parent owned by the same user.
--   * deleted_at is a soft delete so deletions sync reliably.
--   * enums are text + check constraints: cheaper to evolve than Postgres enums.

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- profiles: one row per auth user, created by trigger on sign-up
-- ---------------------------------------------------------------------------

create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  birth_year   smallint check (birth_year between 1900 and 2100),
  sex          text check (sex in ('male', 'female')),
  height_cm    double precision check (height_cm between 50 and 272),
  experience   text not null default 'novice'
               check (experience in ('novice', 'intermediate', 'advanced')),
  unit_system  text not null default 'metric'
               check (unit_system in ('metric', 'imperial')),
  phase        text not null default 'maintain'
               check (phase in ('cut', 'maintain', 'bulk')),
  goal         text,
  equipment    text[] not null default '{}',
  injuries     jsonb not null default '[]',
  timezone     text not null default 'UTC',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1))
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- exercises: user_id null = seeded library (read-only), otherwise custom
-- ---------------------------------------------------------------------------

create table public.exercises (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid references auth.users (id) on delete cascade,
  name              text not null check (length(name) between 1 and 120),
  primary_muscles   text[] not null default '{}',
  secondary_muscles text[] not null default '{}',
  equipment         text not null default 'other'
                    check (equipment in ('barbell', 'dumbbell', 'machine', 'cable',
                                         'bodyweight', 'kettlebell', 'band', 'other')),
  pattern           text
                    check (pattern in ('squat', 'hinge', 'lunge', 'horizontal_push',
                                       'vertical_push', 'horizontal_pull', 'vertical_pull',
                                       'isolation', 'carry', 'core')),
  unilateral        boolean not null default false,
  load_step_kg      double precision not null default 2.5 check (load_step_kg > 0),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz
);

create index exercises_user_id_idx on public.exercises (user_id);

-- ---------------------------------------------------------------------------
-- programs → mesocycles → templates → template_exercises
-- ---------------------------------------------------------------------------

create table public.programs (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name       text not null check (length(name) between 1 and 120),
  goal       text check (goal in ('hypertrophy', 'strength', 'general')),
  status     text not null default 'draft' check (status in ('draft', 'active', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (id, user_id)
);

create table public.mesocycles (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  program_id  uuid not null,
  position    smallint not null default 0,
  weeks       smallint not null default 5 check (weeks between 1 and 16),
  start_date  date,
  deload_week smallint check (deload_week between 1 and 16),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  unique (id, user_id),
  foreign key (program_id, user_id) references public.programs (id, user_id) on delete cascade
);

create table public.templates (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  mesocycle_id  uuid,
  name          text not null check (length(name) between 1 and 120),
  day_index     smallint not null default 0 check (day_index between 0 and 13),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  unique (id, user_id),
  foreign key (mesocycle_id, user_id) references public.mesocycles (id, user_id) on delete cascade
);

create table public.template_exercises (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null default auth.uid() references auth.users (id) on delete cascade,
  template_id       uuid not null,
  exercise_id       uuid not null references public.exercises (id),
  position          smallint not null default 0,
  sets              smallint not null default 3 check (sets between 1 and 20),
  rep_min           smallint not null default 8 check (rep_min between 1 and 100),
  rep_max           smallint not null default 12 check (rep_max between 1 and 100),
  target_rir        double precision check (target_rir between 0 and 10),
  progression_model text not null default 'double'
                    check (progression_model in ('double', 'rpe', 'linear', 'training_max')),
  superset_group    smallint,
  rest_seconds      smallint check (rest_seconds between 0 and 1800),
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  check (rep_min <= rep_max),
  foreign key (template_id, user_id) references public.templates (id, user_id) on delete cascade
);

-- ---------------------------------------------------------------------------
-- sessions → session_exercises → sets
-- ---------------------------------------------------------------------------

create table public.sessions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  template_id uuid,
  name        text,
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  readiness   smallint check (readiness between 0 and 100),
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  unique (id, user_id),
  check (ended_at is null or ended_at >= started_at),
  foreign key (template_id, user_id)
    references public.templates (id, user_id) on delete set null (template_id)
);

create index sessions_user_started_idx on public.sessions (user_id, started_at desc);

create table public.session_exercises (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  session_id  uuid not null,
  exercise_id uuid not null references public.exercises (id),
  position    smallint not null default 0,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  unique (id, user_id),
  foreign key (session_id, user_id) references public.sessions (id, user_id) on delete cascade
);

create table public.sets (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null default auth.uid() references auth.users (id) on delete cascade,
  session_exercise_id uuid not null,
  set_index           smallint not null check (set_index >= 0),
  kind                text not null default 'working'
                      check (kind in ('warmup', 'working', 'top', 'backoff', 'drop', 'amrap', 'failure')),
  weight_kg           double precision check (weight_kg >= 0 and weight_kg <= 1000),
  reps                smallint check (reps between 0 and 200),
  rir                 double precision check (rir between 0 and 10),
  rpe                 double precision check (rpe between 1 and 10),
  e1rm_kg             double precision check (e1rm_kg >= 0),
  is_pr               boolean not null default false,
  logged_at           timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  foreign key (session_exercise_id, user_id)
    references public.session_exercises (id, user_id) on delete cascade
);

create index sets_session_exercise_idx on public.sets (session_exercise_id, set_index);

-- ---------------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['profiles', 'exercises', 'programs', 'mesocycles', 'templates',
                           'template_exercises', 'sessions', 'session_exercises', 'sets']
  loop
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.set_updated_at()',
      t || '_set_updated_at', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- row-level security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;

create policy "profiles: owner can read" on public.profiles
  for select to authenticated using ((select auth.uid()) = id);
create policy "profiles: owner can insert" on public.profiles
  for insert to authenticated with check ((select auth.uid()) = id);
create policy "profiles: owner can update" on public.profiles
  for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

alter table public.exercises enable row level security;

create policy "exercises: read library and own" on public.exercises
  for select to authenticated using (user_id is null or (select auth.uid()) = user_id);
create policy "exercises: owner can insert" on public.exercises
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "exercises: owner can update" on public.exercises
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "exercises: owner can delete" on public.exercises
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Every other table is owner-only for every operation.
do $$
declare
  t text;
begin
  foreach t in array array['programs', 'mesocycles', 'templates', 'template_exercises',
                           'sessions', 'session_exercises', 'sets']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for all to authenticated '
      'using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)',
      t || ': owner only', t);
  end loop;
end;
$$;

grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on
  public.exercises, public.programs, public.mesocycles, public.templates,
  public.template_exercises, public.sessions, public.session_exercises, public.sets
  to authenticated;

-- ---------------------------------------------------------------------------
-- PowerSync replicates from this publication (name must be "powersync").
-- Later migrations add their tables with: alter publication powersync add table ...
-- ---------------------------------------------------------------------------

create publication powersync for table
  public.profiles, public.exercises, public.programs, public.mesocycles, public.templates,
  public.template_exercises, public.sessions, public.session_exercises, public.sets;

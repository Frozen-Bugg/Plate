-- progression_state (Phase 1): what the growth engine decided for each exercise.
--
-- One row per (user, exercise). The engine in packages/engine computes these
-- values; the app and the coach only read them. Keeping the decision here
-- rather than recomputing it on every screen means the next target survives a
-- reinstall, and the coach sees exactly what the lifter saw.

create table public.progression_state (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  exercise_id   uuid not null references public.exercises (id) on delete cascade,
  model         text not null default 'double'
                check (model in ('double', 'linear', 'rpe', 'training_max')),
  next_load_kg  double precision check (next_load_kg >= 0),
  next_reps     smallint check (next_reps between 1 and 100),
  stall_count   smallint not null default 0 check (stall_count >= 0),
  best_e1rm_kg  double precision check (best_e1rm_kg >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  unique (id, user_id),
  -- The engine keeps one verdict per exercise, not a history.
  unique (user_id, exercise_id)
);

-- Note the plain foreign key, not the composite (exercise_id, user_id) used by
-- every other child table. exercises.user_id is null for the seeded library, so
-- a composite key would reject state for any shared exercise — which is most of
-- them. Ownership is still enforced: progression_state.user_id carries its own
-- RLS policy, and a row can only ever be read or written by its owner.

create index progression_state_exercise_idx
  on public.progression_state (user_id, exercise_id);

create trigger progression_state_set_updated_at
  before update on public.progression_state
  for each row execute function public.set_updated_at();

alter table public.progression_state enable row level security;

create policy "progression_state: owner only" on public.progression_state
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.progression_state to authenticated;

alter publication powersync add table public.progression_state;

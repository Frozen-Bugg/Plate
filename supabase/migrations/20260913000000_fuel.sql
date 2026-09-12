-- Phase 3 (Fuel): foods, recipes, meals and the targets they are judged against.
--
--   foods              one row per thing this lifter eats
--   recipes            → recipe_items   something cooked from several foods
--   meals              → meal_items     what was actually eaten, and when
--   nutrition_targets  what to aim for, effective-dated
--
-- Two decisions here are worth reading before changing anything.
--
-- **Foods are per user, never shared.** USDA and Open Food Facts hold millions
-- of rows between them; syncing that to a phone is absurd, and syncing a subset
-- means deciding which subset on the server. So search hits those APIs online,
-- and the moment a food is actually used it is copied into the lifter's own
-- `foods` row. That copy is what gets synced, so logging works on aeroplane
-- mode and in basement gyms, which is where food logging actually happens.
-- `source` and `source_id` remember where the copy came from, so the same
-- barcode scanned twice can be recognised rather than duplicated.
--
-- Because every food belongs to someone, children reference it with the
-- composite `(food_id, user_id)` key the rest of this schema uses. This is the
-- opposite of the `progression_state` → `exercises` case, and for the opposite
-- reason: exercises have a shared library with a null user_id, foods do not.
--
-- **meal_items keep their own copy of the numbers.** A logged meal stores the
-- kcal and macros it contained at the time, not just a pointer to the food. Food
-- databases are corrected constantly — brands reformulate, OFF entries get
-- fixed — and a correction in November must not silently rewrite what March
-- says you ate. The link to the food stays, for editing and for "log it again".
--
-- `meal_plans` is in docs/PLAN.md §8 under this phase, but the roadmap builds
-- meal plans in Phase 5 alongside the generator that fills them. Its shape
-- should follow that generator rather than be guessed at now, so it is not
-- created here.

-- ---------------------------------------------------------------------------
-- foods
-- ---------------------------------------------------------------------------

create table public.foods (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name          text not null check (length(name) between 1 and 200),
  brand         text check (length(brand) <= 200),

  -- Where this copy came from, and its id there, so the same product scanned or
  -- searched twice is recognised instead of duplicated.
  source        text not null default 'custom'
                check (source in ('custom', 'usda', 'off', 'label', 'coach')),
  source_id     text check (length(source_id) <= 120),
  barcode       text check (barcode ~ '^[0-9]{6,14}$'),

  -- Nutrition is stored per 100 g, or per 100 ml when the food is a liquid.
  -- One canonical basis means a portion is always a multiplication, never a
  -- unit conversion (CLAUDE.md: store metric, convert only when displaying).
  basis         text not null default 'g' check (basis in ('g', 'ml')),
  kcal_per_100  double precision not null check (kcal_per_100 between 0 and 900),
  protein_per_100 double precision not null default 0
                  check (protein_per_100 between 0 and 100),
  carb_per_100    double precision not null default 0
                  check (carb_per_100 between 0 and 100),
  fat_per_100     double precision not null default 0
                  check (fat_per_100 between 0 and 100),
  fibre_per_100   double precision check (fibre_per_100 between 0 and 100),
  sugar_per_100   double precision check (sugar_per_100 between 0 and 100),
  sat_fat_per_100 double precision check (sat_fat_per_100 between 0 and 100),
  sodium_mg_per_100 double precision check (sodium_mg_per_100 between 0 and 100000),

  -- The portion the lifter thinks in: "1 slice", 34 g. Optional, because plenty
  -- of foods are only ever weighed.
  serving_g     double precision check (serving_g between 0.1 and 5000),
  serving_label text check (length(serving_label) <= 60),

  -- Bumped on every use so "recents" is a query rather than another table.
  last_used_at  timestamptz,
  favourite     boolean not null default false,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  unique (id, user_id)
);

create index foods_user_name_idx on public.foods (user_id, lower(name));
create index foods_user_recent_idx on public.foods (user_id, last_used_at desc);
-- One row per barcode per lifter, so scanning the same tin twice finds the
-- first copy. Partial, like every uniqueness rule in this schema, so a deleted
-- food does not block re-adding it.
create unique index foods_one_per_barcode
  on public.foods (user_id, barcode)
  where barcode is not null and deleted_at is null;

-- ---------------------------------------------------------------------------
-- recipes → recipe_items  ("weigh the pot")
-- ---------------------------------------------------------------------------
--
-- total_weight_g is what the finished dish weighed, which is the only honest
-- way to portion something cooked: water boils off, and a quarter of the pan by
-- weight is a quarter of the recipe whatever the ingredients did.

create table public.recipes (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name           text not null check (length(name) between 1 and 200),
  servings       smallint check (servings between 1 and 100),
  total_weight_g double precision check (total_weight_g between 1 and 50000),
  notes          text,
  last_used_at   timestamptz,
  favourite      boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  unique (id, user_id)
);

create index recipes_user_name_idx on public.recipes (user_id, lower(name));

create table public.recipe_items (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  recipe_id   uuid not null,
  food_id     uuid not null,
  position    smallint not null default 0,
  quantity_g  double precision not null check (quantity_g between 0 and 50000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  foreign key (recipe_id, user_id) references public.recipes (id, user_id) on delete cascade,
  -- As in meal_items: a food a recipe is built from cannot be hard-deleted, and
  -- no action leaves account deletion free to take both in one statement.
  foreign key (food_id, user_id) references public.foods (id, user_id)
);

create index recipe_items_recipe_idx on public.recipe_items (recipe_id, position);

-- ---------------------------------------------------------------------------
-- meals → meal_items
-- ---------------------------------------------------------------------------
--
-- Several meals a day, so this is deliberately *not* one row per day: the day
-- is a query over meal_on, and daily_rollup is where the day's totals live.

create table public.meals (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  meal_on    date not null,
  slot       text not null default 'snack'
             check (slot in ('breakfast', 'lunch', 'dinner', 'snack', 'other')),
  name       text check (length(name) <= 120),
  logged_at  timestamptz not null default now(),
  notes      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (id, user_id)
);

create index meals_user_day_idx on public.meals (user_id, meal_on desc);

create table public.meal_items (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  meal_id    uuid not null,

  -- Exactly one of these. A meal item is a food or a portion of a recipe.
  food_id    uuid,
  recipe_id  uuid,

  position   smallint not null default 0,
  quantity_g double precision not null check (quantity_g between 0 and 50000),

  -- What it contained when it was logged. See the note at the top: a database
  -- correction must not rewrite history.
  kcal       double precision not null check (kcal between 0 and 30000),
  protein_g  double precision not null default 0 check (protein_g between 0 and 2000),
  carb_g     double precision not null default 0 check (carb_g between 0 and 2000),
  fat_g      double precision not null default 0 check (fat_g between 0 and 2000),
  fibre_g    double precision check (fibre_g between 0 and 500),

  -- How it got here. 'photo', 'voice' and 'label' arrive with the coach in
  -- Phase 4, and every one of them is confirmed by the lifter before it lands.
  source     text not null default 'manual'
             check (source in ('manual', 'barcode', 'recent', 'copy', 'recipe',
                               'photo', 'voice', 'label')),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (num_nonnulls(food_id, recipe_id) = 1),
  foreign key (meal_id, user_id) references public.meals (id, user_id) on delete cascade,
  -- No action rather than cascade or set null, and the difference matters.
  -- Cascading would delete meals because a food was tidied up; setting null
  -- would leave an item that is neither a food nor a recipe, which the check
  -- above forbids. No action says the real rule: a food that has been eaten
  -- cannot be hard-deleted. Removing a food from the list is a soft delete, and
  -- the history keeps pointing at it. (No action rather than restrict so that
  -- deleting the account still takes everything at once, in one statement.)
  foreign key (food_id, user_id) references public.foods (id, user_id),
  foreign key (recipe_id, user_id) references public.recipes (id, user_id)
);

create index meal_items_meal_idx on public.meal_items (meal_id, position);

-- ---------------------------------------------------------------------------
-- nutrition_targets
-- ---------------------------------------------------------------------------
--
-- Effective-dated rather than one live row. Targets change as the phase changes
-- and as adaptive TDEE learns, and a weekly review that cannot see what the
-- target *was* in March cannot explain March. The current target is the newest
-- row whose effective_from has arrived.

create table public.nutrition_targets (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  effective_from date not null,

  kcal           integer not null check (kcal between 800 and 12000),
  protein_g      double precision not null check (protein_g between 0 and 500),
  carb_g         double precision not null check (carb_g between 0 and 1500),
  fat_g          double precision not null check (fat_g between 0 and 500),
  fibre_g        double precision check (fibre_g between 0 and 200),
  water_ml       integer check (water_ml between 0 and 10000),

  -- The optional training-day carb shift (docs/PLAN.md §6): move this share of
  -- carbohydrate from rest days onto training days, weekly total unchanged.
  training_day_carb_shift_pct smallint
                 check (training_day_carb_shift_pct between 0 and 50),

  -- Where the numbers came from. The engine proposes, the lifter approves, and
  -- the coach's proposals go through ai_proposals before they ever land here.
  source         text not null default 'engine'
                 check (source in ('engine', 'manual', 'coach')),

  -- The maintenance estimate these targets were built on, kept so a later
  -- review can see what the engine believed at the time.
  tdee_kcal      integer check (tdee_kcal between 800 and 12000),

  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  unique (id, user_id)
);

create unique index nutrition_targets_one_per_day
  on public.nutrition_targets (user_id, effective_from)
  where deleted_at is null;

create index nutrition_targets_user_from_idx
  on public.nutrition_targets (user_id, effective_from desc);

-- ---------------------------------------------------------------------------
-- updated_at, RLS, grants, replication
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['foods', 'recipes', 'recipe_items', 'meals',
                           'meal_items', 'nutrition_targets']
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

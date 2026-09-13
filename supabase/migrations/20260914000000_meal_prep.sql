-- Meal prep: a cook that happened, and the portions that came out of it.
--
-- docs/MEAL-PLANNING.md §6. A recipe says how to make something; a prep batch
-- records that you did, on a day, in a quantity, and how much is left.
--
-- Two things are load-bearing here.
--
-- Servings remaining is *derived* — made, minus the portions logged against the
-- batch — rather than a column counting down. Two devices decrementing the same
-- counter is a bug that only shows up on the second phone; two devices
-- inserting meal_items is the append-only path everything else already takes.
--
-- cooked_weight_g lives on the batch rather than on the recipe, because it
-- changes. Macros come from the raw ingredients and portions come from the
-- cooked weight: 300 g of dry rice is 300 g of rice macros whether or not it
-- absorbed 600 g of water, but the portion is measured out of the pan. The same
-- chilli cooked down twenty minutes longer is a different weight and the same
-- food. recipes.total_weight_g stays as the expected yield, which is what seeds
-- this field when a cook is logged.

create table public.prep_batches (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  recipe_id       uuid not null,

  cooked_on       date not null,
  servings_made   smallint not null check (servings_made between 1 and 100),

  -- What came out of the pan. Null when it was not weighed, in which case the
  -- app portions by the recipe's raw weight and says so.
  cooked_weight_g double precision check (cooked_weight_g between 1 and 50000),

  -- When it stops being food. Set from the recipe or by hand; a batch with
  -- servings left and a use_by in the past is the thing worth surfacing,
  -- because wasted prep is the main reason people stop prepping.
  use_by          date,

  notes           text,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  unique (id, user_id),
  foreign key (recipe_id, user_id) references public.recipes (id, user_id) on delete cascade
);

create index prep_batches_user_cooked_idx
  on public.prep_batches (user_id, cooked_on desc);

-- Which batch a logged portion came out of.
--
-- Nullable: most meal items are not prepped, and a portion can be logged from a
-- recipe without a batch behind it. When it is set, it is what makes servings
-- remaining derivable.
alter table public.meal_items
  add column prep_batch_id uuid,
  add constraint meal_items_prep_batch_fkey
    foreign key (prep_batch_id, user_id)
    references public.prep_batches (id, user_id);

create index meal_items_prep_batch_idx
  on public.meal_items (prep_batch_id)
  where prep_batch_id is not null;

-- A portion out of a batch is a portion of its recipe. The existing check
-- (num_nonnulls(food_id, recipe_id) = 1) already forces recipe_id to be set,
-- so this only rules out pointing at a batch of something else.
alter table public.meal_items
  add constraint meal_items_prep_batch_needs_recipe
    check (prep_batch_id is null or recipe_id is not null);

-- 'prep' joins the list: a portion logged from the fridge, which is neither a
-- fresh recipe entry nor a manual one.
alter table public.meal_items
  drop constraint meal_items_source_check;
alter table public.meal_items
  add constraint meal_items_source_check
    check (source in ('manual', 'barcode', 'recent', 'copy', 'recipe', 'prep',
                      'photo', 'voice', 'label'));

do $$
begin
  execute 'create trigger prep_batches_set_updated_at before update on public.prep_batches '
          'for each row execute function public.set_updated_at()';
  execute 'alter table public.prep_batches enable row level security';
  execute 'create policy "prep_batches: owner only" on public.prep_batches for all to authenticated '
          'using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)';
  execute 'grant select, insert, update, delete on public.prep_batches to authenticated';
  execute 'alter publication powersync add table public.prep_batches';
end;
$$;

-- What to buy, ticked off in a shop.
--
-- docs/MEAL-PLANNING.md §7. The list is derived from a week's cooks and then
-- edited: summed by food, converted to shopping units, and from that point it
-- belongs to whoever is holding the phone in the aisle.
--
-- There is deliberately no plan table behind it. A week's plan is a decision
-- made once — these cooks, this many servings — and the two things that outlive
-- it are the list you shop from and the batches you log when you actually cook.
-- Storing the plan as well would give three places for the same week to
-- disagree.

create table public.grocery_lists (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name       text not null default 'Shopping' check (length(name) between 1 and 200),

  -- The week it was built for, for naming it and for clearing out old ones.
  for_week   date,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (id, user_id)
);

create index grocery_lists_user_idx
  on public.grocery_lists (user_id, created_at desc);

create table public.grocery_items (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  list_id    uuid not null,

  -- The name is stored rather than only referenced. A shopping list has to
  -- survive the food being renamed or tidied away, and "600 g of something
  -- deleted" is not a line anyone can shop from.
  name       text not null check (length(name) between 1 and 200),
  food_id    uuid,

  quantity_g double precision check (quantity_g between 0 and 100000),

  -- Whether it was derived from the plan or added by hand in the shop. Kept so
  -- rebuilding a list can leave the hand-added lines alone.
  from_plan  boolean not null default true,
  checked    boolean not null default false,

  position   smallint not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (id, user_id),
  foreign key (list_id, user_id) references public.grocery_lists (id, user_id) on delete cascade,
  -- No action, like meal_items: a food that has been shopped for cannot be
  -- hard-deleted, and the list keeps pointing at it through a soft delete.
  foreign key (food_id, user_id) references public.foods (id, user_id)
);

create index grocery_items_list_idx on public.grocery_items (list_id, position);

do $$
declare
  t text;
begin
  foreach t in array array['grocery_lists', 'grocery_items']
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

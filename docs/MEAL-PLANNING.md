# Recipes, meal planning and food suggestions

How the Fuel pillar gets a planning half, and where the line falls between the
coach and the UI. Read [PLAN.md](PLAN.md) §6 and §7 first — the phases, the
macro rules and the agent harness are there, and this only decides the shape of
one feature.

---

## 1. The question

> Will this be better in agentic mode or UI?

Neither, and the split is not a compromise — there is a real line and it is easy
to find. **Ask whether the task has a right answer.**

A task with one correct answer must never go through a model. "How many
calories are left today" is arithmetic over the log; a model that gets it right
99 times and wrong once is worse than useless, because you stop checking. A
task with no correct answer — what to eat, how to spend 620 kcal, what to cook
with what is in the fridge — is exactly what a model is for, and a UI for it is
a worse version of a search box.

| Task | Has a right answer? | Owner |
|---|---|---|
| Calories and macros left today | yes, arithmetic | **engine + UI** |
| Recipe totals and per-serving macros | yes, a sum over rows | **engine + UI** |
| Create, edit, scale, favourite a recipe | yes, it is data entry | **UI** |
| Log a recipe to a meal | yes | **UI** |
| "What should I eat with 620 kcal and 48 g protein left?" | no | **coach** |
| "Plan tomorrow around chicken, rice and eggs" | no | **coach** |
| "Turn this into a recipe I can reuse" | partly | **coach drafts, UI confirms** |
| "Why is my protein always short by 6 pm?" | no | **coach** |

The mistake to avoid is building the left column twice. A "smart" calorie
budget that asks a model what is left, when `daily_rollup` already knows, is
slower, costs money, and can be wrong.

### So: UI owns the nouns, the coach owns the verbs

Recipes, the day log, targets and the remaining budget are **nouns** — things
that exist, get edited, and must be exact. They live in Fuel, as screens.

Suggesting, planning, adapting and explaining are **verbs** that need
judgement. They live in the coach.

They meet at one component: **the confirm card**, which already exists.

---

## 2. One coach, two doors

Do not build a second chat. `quick_add_sheet.dart` already proves the pattern —
the coach proposes an itemised list, you correct it, the device writes it — and
a meal-planning chat that reimplements that gets a second set of bugs.

- **The Coach tab** is the general thread, as now.
- **Fuel gets a button** — *What should I eat?* — that opens the same chat with
  the day's context already attached and a question pre-filled. Same API, same
  tools, same cards, one implementation.

The second door matters because the question is always asked from Fuel, at 6 pm,
looking at the rings. Making him navigate to a different tab and re-explain the
situation is how the feature goes unused.

---

## 3. What the model may and may not produce

This is the part the schema already settles, and it is worth saying plainly
because PLAN.md §11 lists "AI invents numbers" as a top risk.

**`recipe_items.food_id` is `not null`.** A recipe cannot contain an ingredient
that is not a real row in `foods`. So:

> The model names foods and quantities. The server resolves those names to
> `food_id`s and computes every macro by summing real rows. The model never
> states a macro it made up, because it is never asked for one.

A structural guarantee, not a prompt instruction. If the model asks for a food
that does not exist, the server has three honest options, in order:

1. match an existing `foods` row (his own, or one already pulled from Open Food
   Facts);
2. search Open Food Facts and create the row from a real product;
3. fall back to the existing `/parse-food` estimator, which creates the food
   with `source = 'coach'` — **flagged in the card as an estimate**, because a
   coach-estimated 100 g of "chicken curry" is a guess and should look like one.

Option 3 is why `foods.source` exists. A plan built on estimates is fine; a plan
that hides which parts are estimates is not.

The same rule covers the budget. The coach is *given* the remaining kcal and
macros in its context — it never computes them, and never restates one it was
not given. That is already enforced by the eval suite's `grounded` check.

---

## 4. The cards

Five, all rendered inline in the chat, all editable before anything is written.

**Suggestion card** — the answer to "what should I eat?"

```
620 kcal left · 48 g protein left
┌──────────────────────────────────────────┐
│ Greek yoghurt + berries + whey    412 kcal│  P 44  C 38  F 6   [Log]
│ Chicken wrap                      598 kcal│  P 46  C 52  F 18  [Log]
│ 2 eggs on toast + protein shake   540 kcal│  P 42  C 40  F 20  [Log]
└──────────────────────────────────────────┘
```

Three options, not one — the whole point is choosing. Each row shows what it
does to the day's remainder. `[Log]` opens the existing quantity sheet, so the
grams are correctable before it is written.

**Recipe card** — the answer to "make me a recipe for that"

```
Chicken rice bowl                      4 servings
  Chicken breast, raw          600 g
  White rice, dry              300 g
  Broccoli                     400 g
  Olive oil                     30 g
─────────────────────────────────────────────────
per serving   612 kcal   P 52   C 64   F 15
                        [Save recipe]  [Log one serving]
```

Ingredients are editable rows; macros recompute from the food rows as you edit,
on the device, with no model call. `[Save recipe]` writes `recipes` +
`recipe_items`. `[Log one serving]` writes a `meal_items` row with `recipe_id`
set — which the schema and `meals_repository.dart` already support.

**Day plan card** — the answer to "plan tomorrow"

Four meal rows with kcal and protein, totalling to the target, each expandable
into a recipe card. `[Accept]` saves the recipes and the plan; it does **not**
log the food. You log what you actually ate, which is the only thing adaptive
TDEE can trust.

**Prep card** — the answer to "sort my week out"

```
Sunday cook · 2 batches · covers 6 lunches
┌────────────────────────────────────────────────┐
│ Chicken rice bowl        × 4 servings   612 ea │  Mon–Wed
│ Beef chilli              × 3 servings   584 ea │  Thu–Sat
└────────────────────────────────────────────────┘
2 portions of chilli already in the fridge, use by Thu — Monday is covered.
                          [Save cooks]  [Build grocery list]
```

The last line is the whole reason `get_prep_on_hand` exists: the plan is
*reduced* by what is already cooked, rather than cheerfully telling you to make
food you have.

**Grocery card** — ingredients summed across the plan, in shopping units, with
`[Add to list]`. From there it is the grocery screen's problem, because ticking
things off happens in a shop and not in a chat.

---

## 5. New tools

Read tools, added to the nine in `coach-api/src/tools/read.ts`:

| Tool | Returns |
|---|---|
| `get_remaining_today` | target, logged so far, and what is left — kcal and each macro, from the engine |
| `search_recipes` | his own saved recipes, with per-serving macros |
| `get_prep_on_hand` | batches with servings left, their per-serving macros, and how long they keep |

`search_foods`, `query_nutrition` and the rest already exist and cover the
remainder.

`get_prep_on_hand` earns its place by being the only one of these the coach
should reach for *first*. The best answer to "what should I eat" is usually
already cooked, and a coach that suggests a recipe while two portions of chilli
go off in the fridge is worse than no coach.

Draft tools, which return a proposal and write nothing:

| Tool | Returns |
|---|---|
| `draft_recipe` | named ingredients + grams → server resolves and costs them → a recipe card |
| `draft_day_plan` | meals for a day against the target, built around existing prep → a day plan card |
| `draft_prep_plan` | a week as two or three cooks → batches to make, scaled to the servings the week needs |
| `draft_grocery_list` | a plan → ingredients summed by food, in shopping units |

`draft_*` rather than `propose_*` on purpose. PLAN.md's `propose_*` family goes
through `ai_proposals` and the inbox, which is Phase 5; these follow the path
food logging already uses — server returns it, the device shows it, the device
writes on approval. Nothing about the AI-never-writes rule is weakened, and the
inbox is not pulled forward. When Phase 5 lands, these cards graduate into it.

---

## 6. Meal prep

Cook once, eat four times. It is how the week actually gets eaten, and it
changes the shape of everything above: a week is not 21 decisions, it is two or
three cooks and a lot of reheating.

### A batch is a thing that exists

`recipes` describes how to make it. **`prep_batches` records that you did**, on
a day, in a quantity, and how much is left.

```
prep_batches
  recipe_id          what was cooked
  cooked_on          when
  servings_made      how many portions
  cooked_weight_g    what it actually weighed out of the pan
  use_by             cooked_on + keeps_days, or set by hand
```

`meal_items` gains a nullable `prep_batch_id`. Servings remaining is then
**derived** — made, minus the portions logged against it — rather than a counter
to keep in step. PLAN.md's sync rules are append-only-and-recompute for exactly
this reason: two devices decrementing the same counter is a bug, two devices
inserting meal items is not.

### Raw ingredients, cooked portions

The detail that makes prep macros wrong everywhere else, and the reason
`cooked_weight_g` is on the batch rather than the recipe:

> **Macros come from the raw ingredients. Portions come from the cooked
> weight.**

300 g of dry rice is 300 g of rice macros whether or not it absorbed 600 g of
water. But the portion you eat is measured out of a pan holding 1,330 g of
finished food. So the batch's macros are the sum of its `recipe_items`, and a
portion is `cooked_weight_g / servings_made` — or, if you weigh the tub,
whatever grams you actually took.

Cooked weight is per *batch*, not per recipe, because it changes: the same chilli
cooked down twenty minutes longer is a different weight and the same macros.
`recipes.total_weight_g` stays as the expected yield, which is what seeds the
field when you log a cook.

### What this does to the rest

- **Logging gets much cheaper.** Lunch is two taps — the batch, and one
  serving — with the macros already exact because they came from the raw
  ingredients you weighed on Sunday.
- **The coach knows what is in the fridge.** Not from a pantry: from batches
  with servings left and a `use_by`. "You have two portions of chilli that need
  eating by Thursday, and they fit tonight's remaining 620 kcal" is a better
  answer than anything it could invent, and it costs no extra data entry.
- **Aging food gets named.** A batch approaching `use_by` with servings left is
  a fact worth surfacing in Today and in the suggestion card. Wasted prep is the
  main reason people stop prepping.

### Why this is not the pantry I argued against

A pantry is a second inventory of everything you own, maintained by hand, and it
goes stale the first time you eat something without telling the app — after
which the coach confidently suggests a meal around a chicken breast that is not
there.

A prep batch cannot go stale that way. **The app is the only thing that creates
or consumes it**: it exists because you logged a cook, and it depletes because
you logged a portion. The inventory is a side effect of logging you were doing
anyway.

Loose ingredients stay conversational — "I've got chicken, rice and spinach" in
the message, for the turn that needs it. Zero schema, and it is how anyone
actually asks.

---

## 7. Groceries

The list is the other half of a plan: a plan you cannot shop for is a wish.

**It is derived, then edited.** Take the week's plan, expand every recipe and
every prep batch into ingredients, sum by food, and convert to shopping units —
`600 g chicken breast`, not four rows of `150 g`. Then it is yours: tick, add,
remove, and the ticks persist, because the list is read in a shop on a phone
with one hand.

```
grocery_items
  list_id, food_id, name     what to buy (name survives a deleted food)
  quantity_g                 summed across the plan
  from_plan                  true if derived, false if you added it
  checked                    ticked in the aisle
```

Three things that make it worth using rather than a toy:

- **Aggregated by food, not by meal.** The chicken in three different meals is
  one line on the list.
- **Sane units.** 1,340 g of chicken reads as `1.4 kg`; eggs read as `12`, not
  `720 g`. A shopping list in grams is a list written for a database.
- **What you already have comes off it.** Not via a pantry — by ticking. The
  first pass down the list is "have it, have it, need it", which is the same
  work a pantry would demand, done once, at the moment it is actually true.

Generated from the day plan card and from the Fuel week view, so the path is
plan → prep → shop → cook → log, and each step hands the next one its input.

### Schema

Three tables and one column, which by CLAUDE.md's rule means four edits each:
migration with `user_id` and RLS, a stream in `sync-streams.yaml`, a table in
`powersync_schema.dart`, and a Drift table in `tables.dart`.

| Change | Why |
|---|---|
| `prep_batches` | a cook that happened |
| `meal_items.prep_batch_id` | which portions came out of it |
| `grocery_lists` / `grocery_items` | what to buy, tickable |

---

## 8. Build order

Each step is usable on its own, and each is useful even if the next is never
built.

1. **Recipes UI.** List, detail, create, edit, scale, favourite, log. Schema and
   sync already exist — this is screens and a repository. Closes a Phase 3 gap
   on its own, with no AI involved.
2. **Save a logged meal as a recipe.** One button on a day's meal. Cheapest
   real value in the whole document: the recipes he wants are the meals he has
   already eaten.
3. **Prep batches.** Log a cook, portions derive, logging a prepped lunch is two
   taps, and `use_by` warns before food is wasted. Also with no AI in it.
4. **`get_remaining_today` + the suggestion card**, which reads prep batches
   first — the best answer to "what should I eat" is usually already cooked.
5. **`draft_recipe` + the recipe card**, reusing the recipe UI to render it.
6. **`draft_day_plan` + the day plan card**, planned around prep cooks rather
   than 21 separate meals.
7. **Groceries**, derived from the plan and the batches it implies.
8. **The Fuel door** into the coach, once there is something worth asking.

Steps 1–3 are the Phase 3 gap plus prep, none of it needing a model. Steps 4–7
are Coach v2 work arriving early, which is fine because none of it writes
without approval.

The ordering has one deliberate consequence: **prep lands before planning.** A
day plan that does not know what is already in the fridge plans meals you do not
need to cook, and a grocery list built from it sends you to buy them.

---

## 9. What this deliberately does not do

- **No pantry.** See §6: prep batches are inventory the app maintains for free,
  a pantry is inventory you maintain by hand, and a stale one is worse than
  none. Loose ingredients stay conversational.
- **No automatic logging, ever.** Every card is a proposal, and a plan is not a
  log. Adaptive TDEE is built on what was actually eaten; a plan silently
  logged as food is how the TDEE estimate quietly rots. Prep is the one place
  this will be tempting — the food is cooked, the macros are known, it *feels*
  logged — and it still is not, because a batch in the fridge is not a meal in
  you.
- **No second chat implementation.** One thread, two entry points.
- **No model call for anything the device can compute.** Editing a gram value in
  a recipe card recomputes locally.

---

## 10. Cost

A suggestion turn is two or three model calls with small results. On DeepSeek
Flash at $0.15/M in and $0.60/M out that is well under a tenth of a cent, so a
question a day is pennies a month — the same budget the coach already runs on.
Nothing here needs a bigger model; the arithmetic is all on our side, which is
the point of §3.

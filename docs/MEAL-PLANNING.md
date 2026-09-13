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

Three, all rendered inline in the chat, all editable before anything is written.

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

---

## 5. New tools

Read tools, added to the nine in `coach-api/src/tools/read.ts`:

| Tool | Returns |
|---|---|
| `get_remaining_today` | target, logged so far, and what is left — kcal and each macro, from the engine |
| `search_recipes` | his own saved recipes, with per-serving macros |

`search_foods`, `query_nutrition` and the rest already exist and cover the
remainder.

Draft tools, which return a proposal and write nothing:

| Tool | Returns |
|---|---|
| `draft_recipe` | named ingredients + grams → server resolves and costs them → a recipe card |
| `draft_day_plan` | meals for a day against the target → a day plan card |

`draft_*` rather than `propose_*` on purpose. PLAN.md's `propose_*` family goes
through `ai_proposals` and the inbox, which is Phase 5; these follow the path
food logging already uses — server returns it, the device shows it, the device
writes on approval. Nothing about the AI-never-writes rule is weakened, and the
inbox is not pulled forward. When Phase 5 lands, these cards graduate into it.

---

## 6. Ingredients available

"What can I make with what I have" needs to know what he has, and there are two
ways to know.

**Now: he says so.** "I've got chicken, rice, eggs and some spinach" in the
message. Zero schema, zero maintenance, and it is how anyone actually asks.

**Later, only if he asks twice:** a `pantry` table. A pantry is a second
inventory to keep current, and an out-of-date one is worse than none — it makes
the coach confidently suggest a meal around something that ran out on Tuesday.
PLAN.md §11 lists scope creep with "thin before deep" as the guardrail; this is
exactly that case.

---

## 7. Build order

Each step is usable on its own, and each is useful even if the next is never
built.

1. **Recipes UI.** List, detail, create, edit, scale, favourite, log. Schema and
   sync already exist — this is screens and a repository. Closes a Phase 3 gap
   on its own, with no AI involved.
2. **Save a logged meal as a recipe.** One button on a day's meal. Cheapest
   real value in the whole document: the recipes he wants are the meals he has
   already eaten.
3. **`get_remaining_today` + the suggestion card.** The 6 pm question, which is
   the one that gets asked daily.
4. **`draft_recipe` + the recipe card**, reusing the recipe UI to render it.
5. **`draft_day_plan` + the day plan card.**
6. **The Fuel door** into the coach, once there is something worth asking.

Steps 1–2 are the Phase 3 gap. Steps 3–5 are Coach v2 work arriving early,
which is fine because none of it writes without approval.

---

## 8. What this deliberately does not do

- **No grocery list.** PLAN.md has it under meal plans; it is a list of
  ingredients minus a pantry that does not exist. It becomes real with a pantry.
- **No automatic logging, ever.** Every card is a proposal. Adaptive TDEE is
  built on what was actually eaten, and a plan silently logged as food is how
  the TDEE estimate quietly rots.
- **No second chat implementation.** One thread, two entry points.
- **No model call for anything the device can compute.** Editing a gram value in
  a recipe card recomputes locally.

---

## 9. Cost

A suggestion turn is two or three model calls with small results. On DeepSeek
Flash at $0.15/M in and $0.60/M out that is well under a tenth of a cent, so a
question a day is pennies a month — the same budget the coach already runs on.
Nothing here needs a bigger model; the arithmetic is all on our side, which is
the point of §3.

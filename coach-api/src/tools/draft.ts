import type { ModelClient } from '../model/client.ts';
import { assertMinimal } from '../privacy.ts';
import { ParseError, parseJson } from './parse.ts';

/// "Make me a recipe for that" — ingredients and amounts, and no macros.
///
/// The omission is the design. docs/MEAL-PLANNING.md §3: the model names foods
/// and quantities, and every macro is summed from the food rows on the device.
/// The parsers have to estimate because a sandwich somebody ate has no row
/// behind it; a recipe does, by the time it is saved, because
/// `recipe_items.food_id` is NOT NULL and the schema will not hold one
/// otherwise.
///
/// So this is the one place where the rule costs nothing to enforce
/// completely: the model is never asked for a number it could get wrong, and
/// a recipe's calories are therefore never a guess.

export interface DraftIngredient {
  /// What to look for, as a food would be named. "Chicken breast", not
  /// "Succulent free-range chicken".
  name: string;
  grams: number;
  /// Anything worth seeing — "raw weight", "dry". Optional and short.
  note?: string;
}

export interface DraftRecipe {
  name: string;
  servings: number;
  ingredients: DraftIngredient[];
  /// What the model wants to say about the method, if anything. One or two
  /// sentences; the app stores it as the recipe's notes.
  method?: string;
}

const prompt = `
You turn a description of a dish into a recipe: a name, how many servings it
makes, and what goes in it by weight. You do not chat or greet.

Reply with JSON only. No prose, no markdown fence.

{"name":"Chicken rice bowl","servings":4,"ingredients":[{"name":"Chicken breast","grams":600,"note":"raw weight"},{"name":"White rice","grams":300,"note":"dry"}],"method":"Roast the chicken, boil the rice, combine."}

Rules:

- **Never state calories or macros.** Not per ingredient, not per serving, not
  anywhere. They are computed from a food database once the ingredients are
  matched up, and a number from you would only be wrong.
- Name ingredients the way a food database does: "Chicken breast", "Olive oil",
  "White rice". Not a brand, not a description, not a phrase.
- Weigh everything in grams, for the whole dish rather than per serving. Use
  raw or dry weights and say which in "note" — that is what gets weighed.
- Oil, butter and sauces count. They are most of what goes wrong in a recipe's
  calories and the easiest thing to leave out.
- "servings" is how many portions the dish makes. Say 1 if it is for one meal.
- Keep it to what was asked for. Do not add a side nobody mentioned.
- "method" is optional and at most two sentences. Leave it out for something
  that needs no explaining.

If the description names no dish at all, reply
{"name":"","servings":1,"ingredients":[]}.
`.trim();

/// Drafts a recipe from a description. Throws when nothing usable comes back.
export async function draftRecipe(
  model: ModelClient,
  text: string,
): Promise<DraftRecipe> {
  const said = text.trim();
  if (!said) throw new ParseError('Nothing to make a recipe from.');
  if (said.length > 2000) {
    throw new ParseError('That is too long to turn into one recipe.');
  }

  const reply = await model.send({
    system: prompt,
    messages: [{ role: 'user', text: said }],
    // No tools: this is a parse, and a model that can call something will.
    maxOutputTokens: 2048,
    effort: 'low',
  });

  return assertMinimal(validate(parseJson(reply.text)), 'draft_recipe');
}

function validate(value: unknown): DraftRecipe {
  if (typeof value !== 'object' || value === null) {
    throw new ParseError('The coach did not answer with a recipe.');
  }
  const raw = value as Record<string, unknown>;

  const name = typeof raw.name === 'string' ? raw.name.trim() : '';
  const rows = Array.isArray(raw.ingredients) ? raw.ingredients : [];

  const ingredients: DraftIngredient[] = [];
  for (const entry of rows.slice(0, 40)) {
    if (typeof entry !== 'object' || entry === null) continue;
    const row = entry as Record<string, unknown>;
    const ingredient = typeof row.name === 'string' ? row.name.trim() : '';
    const grams = Number(row.grams);
    // An ingredient with no weight cannot be costed, and one shown without a
    // weight would be silently left out of the total.
    if (!ingredient || !Number.isFinite(grams) || grams <= 0) continue;

    ingredients.push({
      name: ingredient,
      grams: Math.round(grams),
      ...(typeof row.note === 'string' && row.note.trim()
        ? { note: row.note.trim() }
        : {}),
    });
  }

  if (!name || ingredients.length === 0) {
    throw new ParseError('That did not come out as a recipe. Try describing the dish.');
  }

  const servings = Number(raw.servings);
  return {
    name,
    servings:
      Number.isFinite(servings) && servings >= 1 && servings <= 100
        ? Math.round(servings)
        : 1,
    ingredients,
    ...(typeof raw.method === 'string' && raw.method.trim()
      ? { method: raw.method.trim() }
      : {}),
  };
}

// ---------------------------------------------------------------------------
// A week of cooking
// ---------------------------------------------------------------------------

/// One cook in a week's plan.
///
/// Either a recipe already saved — named exactly, so the device can look it up
/// and cost it — or a new one drafted here, in the same shape as [DraftRecipe].
export interface PlannedCook {
  name: string;
  servings: number;
  /// True when [name] is one of the saved recipes it was given.
  saved: boolean;
  /// Only for a new recipe. Empty for a saved one, which already has its own.
  ingredients: DraftIngredient[];
  /// Which meals this batch is meant to cover — "Mon–Wed lunches".
  covers?: string;
}

export interface PrepPlan {
  cooks: PlannedCook[];
  /// One line on the shape of the week, or what it leaves out.
  note?: string;
}

const planPrompt = `
You plan a week of cooking: two or three batches that cover the meals asked
for. You do not chat or greet.

Reply with JSON only. No prose, no markdown fence.

{"cooks":[{"name":"Chicken rice bowl","servings":4,"saved":true,"ingredients":[],"covers":"Mon-Wed lunches"},{"name":"Beef chilli","servings":3,"saved":false,"ingredients":[{"name":"Beef mince","grams":500,"note":"5% fat"},{"name":"Kidney beans","grams":400}],"covers":"Thu-Sat lunches"}],"note":"Sunday is left free."}

Rules:

- **Never state calories or macros.** They are computed from a food database
  once the ingredients are matched up. A number from you would only be wrong.
- Two or three cooks. A week is not twenty-one decisions, and a plan with a
  different dish every day is one nobody follows.
- **Subtract what is already cooked.** You are told what is in the fridge and
  how many servings are left. Those meals are covered; do not plan a batch to
  replace food that exists.
- Prefer the recipes they have saved. Set "saved" to true and name it exactly as
  given, with an empty "ingredients" — the app has them already.
- For a new dish set "saved" to false and list ingredients in grams for the
  whole batch, the same way a recipe is written. Include oil, butter and sauces.
- "servings" is how many portions that batch makes.
- "covers" is which meals it is for, short. "Mon-Wed lunches".
- "note" is at most one sentence, and only if there is something worth saying.

If there is nothing to plan, reply {"cooks":[]}.
`.trim();

/// Drafts a week of cooking around what is already in the fridge.
export async function draftPrepPlan(
  model: ModelClient,
  input: { onHand: string; recipes: string[]; note?: string },
): Promise<PrepPlan> {
  const context = [
    input.onHand.trim() || 'Nothing cooked in the fridge.',
    input.recipes.length === 0
      ? 'No saved recipes.'
      : `Saved recipes: ${input.recipes.join(', ')}.`,
    input.note?.trim() ? `They said: ${input.note.trim()}` : undefined,
  ]
    .filter(Boolean)
    .join('\n\n');

  const reply = await model.send({
    system: planPrompt,
    messages: [{ role: 'user', text: context }],
    maxOutputTokens: 2048,
    effort: 'low',
  });

  return assertMinimal(validatePlan(parseJson(reply.text)), 'draft_prep_plan');
}

function validatePlan(value: unknown): PrepPlan {
  if (typeof value !== 'object' || value === null) {
    throw new ParseError('The coach did not answer with a plan.');
  }
  const raw = value as Record<string, unknown>;
  const rows = Array.isArray(raw.cooks) ? raw.cooks : [];

  const cooks: PlannedCook[] = [];
  for (const entry of rows.slice(0, 6)) {
    if (typeof entry !== 'object' || entry === null) continue;
    const row = entry as Record<string, unknown>;
    const name = typeof row.name === 'string' ? row.name.trim() : '';
    if (!name) continue;

    const servings = Number(row.servings);
    const saved = row.saved === true;
    const ingredients: DraftIngredient[] = [];
    for (const item of Array.isArray(row.ingredients) ? row.ingredients : []) {
      if (typeof item !== 'object' || item === null) continue;
      const line = item as Record<string, unknown>;
      const ingredient = typeof line.name === 'string' ? line.name.trim() : '';
      const grams = Number(line.grams);
      if (!ingredient || !Number.isFinite(grams) || grams <= 0) continue;
      ingredients.push({
        name: ingredient,
        grams: Math.round(grams),
        ...(typeof line.note === 'string' && line.note.trim()
          ? { note: line.note.trim() }
          : {}),
      });
    }

    // A new dish with nothing in it cannot be shopped for or cooked, and
    // showing it would promise a meal that does not exist.
    if (!saved && ingredients.length === 0) continue;

    cooks.push({
      name,
      servings:
        Number.isFinite(servings) && servings >= 1 && servings <= 100
          ? Math.round(servings)
          : 1,
      saved,
      ingredients,
      ...(typeof row.covers === 'string' && row.covers.trim()
        ? { covers: row.covers.trim() }
        : {}),
    });
  }

  return {
    cooks,
    ...(typeof raw.note === 'string' && raw.note.trim()
      ? { note: raw.note.trim() }
      : {}),
  };
}

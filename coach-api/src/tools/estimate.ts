import type { ModelClient } from '../model/client.ts';
import { assertMinimal } from '../privacy.ts';
import { ParseError, parseJson } from './parse.ts';

/// Per-100 g nutrition for a food nobody has on the shelf yet.
///
/// The third of the three options in docs/MEAL-PLANNING.md §3, and the one that
/// makes a drafted recipe usable. Matching an ingredient against the lifter's
/// own foods answers most of them; Open Food Facts answers the packaged ones;
/// this answers "chicken breast" for somebody who has never logged chicken.
///
/// It is a different job from `draft_recipe`, which is asked for no numbers at
/// all. Naming an ingredient and costing one are separate questions, and mixing
/// them would let a recipe's totals come back from the same breath that invented
/// the ingredient list.
///
/// **An estimate is not a measurement**, and the difference has to survive all
/// the way to the screen. Everything here is created with `source = 'coach'` so
/// the app can say so, and every value is editable before anything is saved.

export interface EstimatedFood {
  /// Echoed back exactly as asked, so the caller can match it up.
  name: string;
  kcalPer100: number;
  proteinPer100: number;
  carbPer100: number;
  fatPer100: number;
  fibrePer100?: number;
  /// What was assumed — "raw", "dry, uncooked", "semi-skimmed". The thing most
  /// likely to be wrong, and the thing worth showing.
  note?: string;
}

const prompt = `
You give the nutrition of a food per 100 grams. You do not chat or greet.

Reply with JSON only. No prose, no markdown fence.

{"foods":[{"name":"Chicken breast","kcalPer100":165,"proteinPer100":31,"carbPer100":0,"fatPer100":3.6,"note":"raw, skinless"}]}

Rules:

- One entry per food asked for, with "name" echoed back **exactly** as it was
  given. Same spelling, same case. It is how the caller matches them up.
- Every number is per 100 g of the food itself, never per serving and never for
  the amount it is going into a recipe.
- Use raw or dry weights where that is how a thing is weighed into a pan — rice
  and pasta are dry, meat is raw. Say which in "note".
- "note" is short and holds what you assumed: raw or cooked, skin on or off, the
  fat percentage of a mince, whether a milk is whole. Leave it out only when
  there is genuinely nothing to assume.
- Calories have to agree with the macros, near enough: protein and carbohydrate
  are about 4 kcal a gram and fat about 9.
- If something is not a food at all, leave it out of the list entirely rather
  than inventing numbers for it.

These are estimates, shown to the lifter as estimates and editable before
anything is saved. Ordinary supermarket versions of things, not best cases.
`.trim();

/// Estimates per-100 g nutrition for each of [names].
///
/// One call for the whole list: a recipe with eight unmatched ingredients would
/// otherwise be eight round trips, and the lifter is watching a spinner.
export async function estimateFoods(
  model: ModelClient,
  names: string[],
): Promise<EstimatedFood[]> {
  const wanted = names
    .map((name) => name.trim())
    .filter((name) => name.length > 0)
    .slice(0, 30);

  if (wanted.length === 0) throw new ParseError('Nothing to look up.');

  const reply = await model.send({
    system: prompt,
    messages: [{ role: 'user', text: wanted.join('\n') }],
    maxOutputTokens: 2048,
    effort: 'low',
  });

  return assertMinimal(validate(parseJson(reply.text)), 'estimate_foods');
}

function validate(value: unknown): EstimatedFood[] {
  if (typeof value !== 'object' || value === null) {
    throw new ParseError('The coach did not answer with any nutrition.');
  }
  const rows = (value as { foods?: unknown }).foods;
  if (!Array.isArray(rows)) {
    throw new ParseError('The coach did not answer with any nutrition.');
  }

  const foods: EstimatedFood[] = [];
  for (const entry of rows.slice(0, 30)) {
    if (typeof entry !== 'object' || entry === null) continue;
    const row = entry as Record<string, unknown>;
    const name = typeof row.name === 'string' ? row.name.trim() : '';
    if (!name) continue;

    const kcal = number(row.kcalPer100);
    // Nothing edible is over 900 kcal per 100 g — pure fat is 900 — so a
    // number past it is a per-serving figure or a slip, and either way it
    // would be rejected by the schema after quietly wrecking the recipe.
    if (kcal === undefined || kcal <= 0 || kcal > 900) continue;

    foods.push({
      name,
      kcalPer100: kcal,
      proteinPer100: bounded(row.proteinPer100),
      carbPer100: bounded(row.carbPer100),
      fatPer100: bounded(row.fatPer100),
      ...(number(row.fibrePer100) === undefined
        ? {}
        : { fibrePer100: bounded(row.fibrePer100) }),
      ...(typeof row.note === 'string' && row.note.trim()
        ? { note: row.note.trim() }
        : {}),
    });
  }

  if (foods.length === 0) {
    throw new ParseError('The coach could not price any of those.');
  }
  return foods;
}

function number(value: unknown): number | undefined {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

/// A macro per 100 g cannot exceed 100 g, and cannot be negative. The schema
/// enforces the same range; clamping here means a slip costs one wrong
/// ingredient rather than the whole recipe.
function bounded(value: unknown): number {
  const parsed = number(value) ?? 0;
  return Math.min(Math.max(parsed, 0), 100);
}

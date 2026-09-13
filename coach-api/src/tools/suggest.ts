import type { CoachData, Macros } from '../data.ts';
import type { ModelClient } from '../model/client.ts';
import { assertMinimal } from '../privacy.ts';
import { ParseError, parseJson } from './parse.ts';

/// "What should I eat?", answered in three options rather than a paragraph.
///
/// A separate route from the chat for the same reason the parsers are: it has
/// one shape of right answer, wants one model call and no history, and the
/// answer is a thing to tap rather than a thing to read.
///
/// The arithmetic is done here and handed over. What is left of the day is
/// subtraction over the log, what is in the fridge is a query, and what a
/// recipe costs is a sum over its ingredients — docs/MEAL-PLANNING.md §1 is
/// that none of those ever go through a model. The model is asked only for the
/// part that has no right answer: what would be a good idea.
///
/// **Nothing is logged.** Each option comes back with its numbers so the
/// device can show them, and logging is a second, deliberate tap.

export interface Suggestion {
  /// What to eat, as a lifter would say it. "Greek yoghurt, berries and whey".
  name: string;
  kcal: number;
  proteinG: number;
  carbG: number;
  fatG: number;
  /// One line on why this one. "Closes the protein gap without the calories."
  why: string;
  /// Set when the option is food already cooked, naming the batch.
  fromPrep?: string;
  /// Set when the option is one of their saved recipes.
  fromRecipe?: string;
}

export interface Suggestions {
  /// What is left of the day, as given to the model. Never computed by it.
  left?: Macros;
  target?: Macros;
  logged: Macros;
  options: Suggestion[];
  /// Said when there is something in the fridge that has to be eaten.
  urgent?: string;
}

const prompt = `
You suggest what to eat next. You do not chat, greet, or explain yourself.

Reply with JSON only. No prose, no markdown fence.

{"options":[{"name":"Greek yoghurt with berries and whey","kcal":412,"proteinG":44,"carbG":38,"fatG":6,"why":"Closes most of the protein gap for a third of the calories.","fromPrep":"Beef chilli"}]}

Rules:

- Exactly three options, different from each other. One large, one moderate,
  one small — the point is choosing, not being told.
- Food already cooked comes first. You are given what is in the fridge with how
  long it keeps; if something has a day left, one option must be that, and its
  "why" must say it needs eating.
- Use "fromPrep" for food already cooked and "fromRecipe" for one of their
  saved recipes, naming it exactly as given. Leave both out for something new.
- For food you were given numbers for, use those numbers exactly. Do not
  re-estimate what you were handed. Only invent numbers for an option that is
  not in the data, and keep those to ordinary portions.
- Fit what is left. An option may be under it; none should be wildly over.
  When what is left is small, say so in a "why" rather than pretending.
- Protein is the macro that matters. Prefer options that close its gap.
- "why" is one short sentence. No exclamation marks, no encouragement.

If nothing is left of the day at all, still give three options and say in each
"why" that it puts them over.
`.trim();

/// Asks for three things worth eating, given what is left and what is cooked.
export async function suggestMeals(
  model: ModelClient,
  input: { data: CoachData; today: string; note?: string },
): Promise<Suggestions> {
  const { data, today } = input;

  const [target, meals, prep, recipes] = await Promise.all([
    data.targetOn(today),
    data.meals(today),
    data.prepOnHand(today),
    data.recipes(),
  ]);

  const logged = meals.reduce(
    (sum, meal) => ({
      kcal: sum.kcal + meal.kcal,
      proteinG: sum.proteinG + meal.proteinG,
      carbG: sum.carbG + meal.carbG,
      fatG: sum.fatG + meal.fatG,
    }),
    { kcal: 0, proteinG: 0, carbG: 0, fatG: 0 },
  );

  const round = (m: Macros): Macros => ({
    kcal: Math.round(m.kcal),
    proteinG: Math.round(m.proteinG),
    carbG: Math.round(m.carbG),
    fatG: Math.round(m.fatG),
  });

  const left = target
    ? round({
        kcal: target.kcal - logged.kcal,
        proteinG: target.proteinG - logged.proteinG,
        carbG: target.carbG - logged.carbG,
        fatG: target.fatG - logged.fatG,
      })
    : undefined;

  const urgent = prep.find((batch) => (batch.daysLeft ?? 99) <= 1);

  const context = [
    left
      ? `Left today: ${left.kcal} kcal, P${left.proteinG} C${left.carbG} F${left.fatG}.`
      : 'No calorie target is set. Suggest ordinary, protein-forward meals.',
    prep.length === 0
      ? 'Nothing cooked in the fridge.'
      : `In the fridge:\n${prep
          .map(
            (batch) =>
              `- ${batch.name}: ${batch.servingsLeft} servings left, ` +
              `${batch.perServing.kcal} kcal and P${batch.perServing.proteinG} each` +
              (batch.daysLeft === undefined
                ? ''
                : batch.daysLeft <= 0
                  ? ', must be eaten today'
                  : batch.daysLeft === 1
                    ? ', must be eaten by tomorrow'
                    : `, keeps ${batch.daysLeft} more days`),
          )
          .join('\n')}`,
    recipes.length === 0
      ? 'No saved recipes.'
      : `Saved recipes:\n${recipes
          .slice(0, 12)
          .map(
            (recipe) =>
              `- ${recipe.name}: ${recipe.perServing.kcal} kcal and ` +
              `P${recipe.perServing.proteinG} a serving`,
          )
          .join('\n')}`,
    input.note?.trim() ? `They said: ${input.note.trim()}` : undefined,
  ]
    .filter(Boolean)
    .join('\n\n');

  const reply = await model.send({
    system: prompt,
    messages: [{ role: 'user', text: context }],
    // No tools: everything it needs is above, and a model that can call
    // something will.
    maxOutputTokens: 2048,
    effort: 'low',
  });

  const options = validate(parseJson(reply.text));

  return assertMinimal(
    {
      logged: round(logged),
      ...(target
        ? {
            target: round({
              kcal: target.kcal,
              proteinG: target.proteinG,
              carbG: target.carbG,
              fatG: target.fatG,
            }),
          }
        : {}),
      ...(left ? { left } : {}),
      ...(urgent
        ? {
            urgent:
              `${urgent.name} — ${urgent.servingsLeft} ` +
              `${urgent.servingsLeft === 1 ? 'serving' : 'servings'} left, ` +
              (urgent.daysLeft !== undefined && urgent.daysLeft <= 0
                ? 'eat it today'
                : 'eat it by tomorrow'),
          }
        : {}),
      options,
    },
    'suggest',
  );
}

function validate(value: unknown): Suggestion[] {
  if (typeof value !== 'object' || value === null) {
    throw new ParseError('The coach did not answer with a suggestion.');
  }
  const raw = (value as { options?: unknown }).options;
  if (!Array.isArray(raw)) {
    throw new ParseError('The coach did not answer with a suggestion.');
  }

  const options: Suggestion[] = [];
  for (const entry of raw.slice(0, 5)) {
    if (typeof entry !== 'object' || entry === null) continue;
    const row = entry as Record<string, unknown>;
    const name = typeof row.name === 'string' ? row.name.trim() : '';
    if (!name) continue;

    options.push({
      name,
      kcal: number(row.kcal),
      proteinG: number(row.proteinG),
      carbG: number(row.carbG),
      fatG: number(row.fatG),
      why: typeof row.why === 'string' ? row.why.trim() : '',
      ...(typeof row.fromPrep === 'string' && row.fromPrep.trim()
        ? { fromPrep: row.fromPrep.trim() }
        : {}),
      ...(typeof row.fromRecipe === 'string' && row.fromRecipe.trim()
        ? { fromRecipe: row.fromRecipe.trim() }
        : {}),
    });
  }

  if (options.length === 0) {
    throw new ParseError('The coach could not think of anything to eat.');
  }
  return options;
}

/// A number, or zero. A suggestion with a missing calorie count is still a
/// suggestion; one that throws is a blank screen.
function number(value: unknown): number {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed) : 0;
}

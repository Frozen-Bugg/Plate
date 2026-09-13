import type { ModelClient } from '../model/client.ts';
import { assertMinimal } from '../privacy.ts';

/// Turning "4 eggs and 2 high protein sandwiches" into something loggable.
///
/// A separate route from the chat, not a tool on it. The chat is a
/// conversation; this is a parse with one right answer, and it wants a tight
/// prompt, one model call, low effort and no history. Running it through the
/// agent loop would cost two calls and invite the model to chat about it.
///
/// **Nothing here is logged automatically.** docs/PLAN.md §11 is explicit that
/// an estimate must be itemised and editable and never written on the model's
/// say-so. This returns a proposal; the device shows it, the lifter corrects
/// it, and the device writes it. That is also why the numbers come back per
/// item rather than as a total: a total cannot be corrected, only accepted or
/// thrown away.

export interface ParsedItem {
  /// What it is, as a lifter would name it. "Eggs", not "Egg, whole, raw".
  name: string;
  /// How many of [unit]. 4 eggs, 2 sandwiches, 200 g of rice.
  quantity: number;
  /// 'item', 'g', 'ml' or 'serving'.
  unit: string;
  /// What that comes to in grams, which is the only thing the schema stores.
  grams: number;
  kcal: number;
  proteinG: number;
  carbG: number;
  fatG: number;
  /// Any assumption worth seeing before accepting it — "assumed large eggs",
  /// "shop-bought, not homemade". Shown under the item.
  note?: string;
}

export interface ParsedMeal {
  slot: string;
  items: ParsedItem[];
}

const slots = ['breakfast', 'lunch', 'dinner', 'snack'];

const prompt = `
You turn a sentence about food into itemised, loggable numbers. You do not
chat, explain, or greet.

Reply with JSON only. No prose, no markdown fence, no commentary.

{"slot":"breakfast","items":[{"name":"Eggs","quantity":4,"unit":"item","grams":200,"kcal":312,"proteinG":25,"carbG":1,"fatG":22,"note":"assumed large"}]}

Rules:

- One entry per distinct food. "4 eggs and 2 sandwiches" is two entries, not one.
- "quantity" and "unit" are how the lifter said it. "grams" is your conversion
  of the whole amount — 4 eggs is about 200 g, not 50.
- kcal and the macros are totals for the whole amount, not per 100 g and not
  per unit.
- Use ordinary portion sizes for the country the food sounds like it is from.
  A large egg is about 50 g. A sandwich is about 150 g.
- "slot" is breakfast, lunch, dinner or snack. Take it from the sentence when
  it says one, otherwise use the slot you were given.
- Put any assumption a reasonable person might disagree with in "note", short.
  Portion size, cooked or raw, whether something was fried. Leave it out when
  there is nothing to say.
- If the sentence names no food at all, reply {"slot":"snack","items":[]}.
- Never invent a food that was not mentioned, and never merge two into one.

Your numbers are estimates and are shown to the lifter to correct before
anything is saved. Being roughly right about everything they said beats being
precise about some of it and silent about the rest.
`.trim();

/// Parses a sentence into items. Throws when the model answers with something
/// that cannot be trusted.
export async function parseMeal(
  model: ModelClient,
  text: string,
  options: { slot?: string } = {},
): Promise<ParsedMeal> {
  const said = text.trim();
  if (!said) throw new ParseError('Nothing to log.');
  if (said.length > 1000) {
    throw new ParseError('That is too long to log in one go.');
  }

  const slot = slots.includes(options.slot ?? '') ? options.slot! : 'snack';

  const reply = await model.send({
    system: prompt,
    messages: [
      { role: 'user', text: `Slot if unstated: ${slot}\n\n${said}` },
    ],
    // No tools: this is a parse, and a model that can call something will.
    maxOutputTokens: 2048,
    effort: 'low',
  });

  return assertMinimal(validate(parseJson(reply.text), slot), 'parse_food');
}

export class ParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ParseError';
  }
}

/// Pulls the JSON out of whatever the model actually said.
///
/// Asking for JSON only gets JSON only most of the time. The rest of the time
/// it arrives fenced, or with a sentence in front of it, and failing on that
/// would be pedantry at the lifter's expense.
function parseJson(text: string): unknown {
  const fenced = /```(?:json)?\s*([\s\S]*?)```/.exec(text);
  const body = fenced?.[1] ?? text;

  const start = body.indexOf('{');
  const end = body.lastIndexOf('}');
  if (start === -1 || end <= start) {
    throw new ParseError('Could not read that as a list of foods.');
  }

  try {
    return JSON.parse(body.slice(start, end + 1));
  } catch {
    throw new ParseError('Could not read that as a list of foods.');
  }
}

/// The rails. Everything here is a number a model made up, so nothing is
/// trusted until it has been shown to be possible.
function validate(raw: unknown, fallbackSlot: string): ParsedMeal {
  if (typeof raw !== 'object' || raw === null) {
    throw new ParseError('Could not read that as a list of foods.');
  }
  const meal = raw as Record<string, unknown>;

  const slot = slots.includes(String(meal.slot)) ? String(meal.slot) : fallbackSlot;
  const list = Array.isArray(meal.items) ? meal.items : [];

  // A sentence with twenty foods in it is a shopping list, not a meal, and
  // twenty made-up estimates is not something anyone will check.
  if (list.length > 20) {
    throw new ParseError('That is too many things to log at once.');
  }

  const items: ParsedItem[] = [];
  for (const entry of list) {
    const item = asItem(entry);
    if (item) items.push(item);
  }
  return { slot, items };
}

function asItem(raw: unknown): ParsedItem | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const item = raw as Record<string, unknown>;

  const name = String(item.name ?? '').trim().slice(0, 80);
  if (!name) return null;

  const grams = number(item.grams);
  const kcal = number(item.kcal);
  // A food with no weight or no energy cannot be logged, and guessing on the
  // model's behalf is how a silent zero ends up in the rollup.
  if (grams === null || grams <= 0 || grams > 5000) return null;
  if (kcal === null || kcal <= 0 || kcal > 10000) return null;

  const proteinG = clamp(number(item.proteinG));
  const carbG = clamp(number(item.carbG));
  const fatG = clamp(number(item.fatG));

  // Atwater: 4/4/9. If the macros cannot account for the calories, one of the
  // two is wrong and the lifter should see the item flagged rather than a
  // confident number that does not add up.
  const fromMacros = proteinG * 4 + carbG * 4 + fatG * 9;
  const mismatched =
    fromMacros > 0 && (fromMacros > kcal * 1.5 || fromMacros < kcal * 0.5);

  const quantity = number(item.quantity);
  const note = String(item.note ?? '').trim().slice(0, 120);

  return {
    name,
    quantity: quantity !== null && quantity > 0 ? quantity : 1,
    unit: ['item', 'g', 'ml', 'serving'].includes(String(item.unit))
      ? String(item.unit)
      : 'item',
    grams,
    kcal,
    proteinG,
    carbG,
    fatG,
    note: mismatched
      ? [note, 'the macros do not add up to the calories — check this one']
          .filter(Boolean)
          .join(' · ')
      : note || undefined,
  };
}

function number(value: unknown): number | null {
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) ? n : null;
}

/// A macro that is negative, absurd or missing is zero. Zero is visible and
/// correctable; NaN reaches the database.
function clamp(value: number | null): number {
  if (value === null || value < 0 || value > 2000) return 0;
  return Math.round(value * 10) / 10;
}

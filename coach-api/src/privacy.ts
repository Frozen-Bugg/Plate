/// What the coach is allowed to be told.
///
/// The lifter's instruction was "the model should be good, and it should not
/// take too much info". The first half is a model choice; this file is the
/// second half, written as a rule the code enforces rather than an intention
/// the next change can quietly drop.
///
/// Three rules, in order of how much they matter.
///
/// **No identifiers leave this server.** Not the user id, not row ids, not the
/// email. The coach works in names and numbers — "Bench Press", 82.5 kg, 2400
/// kcal — which is everything it needs to reason and nothing it needs to
/// identify anybody. When a proposal has to point at a row, the *server*
/// resolves the name back to an id on the way in. A uuid in a prompt is a
/// join key for whoever ends up holding the logs.
///
/// **Aggregates before rows.** The snapshot is built from `daily_rollup`, which
/// is already one row per day. A coach that needs the individual sets asks for
/// them through a tool, for the exercise and the window it actually cares
/// about.
///
/// **Everything is capped.** A tool that returns a thousand rows costs tokens,
/// buries the answer, and sends far more than the question needed.

/// Things that must never appear in anything sent to a model.
///
/// Deliberately a denylist over the *output*, not a promise about the input.
/// Every query is written to select named columns, so nothing should reach here
/// anyway — this is what catches the day someone adds `select=*` to a tool.
const forbidden: { name: string; pattern: RegExp }[] = [
  {
    name: 'an email address',
    pattern: /[\w.+-]+@[\w-]+\.[\w.-]+/,
  },
  {
    name: 'a uuid',
    // Row ids and the user id both. The coach speaks in names.
    pattern:
      /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i,
  },
  {
    name: 'what looks like a token or key',
    // JWTs (three dot-separated base64 segments) and the long opaque keys the
    // Supabase and model clients carry.
    pattern: /\beyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{10,}\b|\bsb_[\w-]{20,}\b|\bAIza[\w-]{20,}\b/,
  },
];

/// The most any single tool result may carry, in characters.
///
/// Roughly 4k tokens. Past that a result is not an answer, it is a haystack,
/// and the model reads it worse than a smaller one.
export const maxResultChars = 16_000;

/// The snapshot's ceiling. docs/PLAN.md §7 budgets it at ~1.5K tokens.
export const maxSnapshotChars = 6_000;

export class PrivacyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PrivacyError';
  }
}

/// Checks a payload on its way to the model, and returns it unchanged.
///
/// Throws rather than redacting. A redaction silently changes what the coach
/// sees, which turns a leak into a subtly wrong answer; a failed tool call is
/// visible, recoverable, and gets fixed.
export function assertMinimal<T>(
  value: T,
  where: string,
  limit = maxResultChars,
): T {
  const text = typeof value === 'string' ? value : JSON.stringify(value ?? null);

  for (const { name, pattern } of forbidden) {
    const match = pattern.exec(text);
    if (match) {
      throw new PrivacyError(
        `${where} was about to send ${name} to the model ` +
          `(“${match[0].slice(0, 12)}…”). The coach works in names and ` +
          'numbers — see src/privacy.ts.',
      );
    }
  }

  if (text.length > limit) {
    throw new PrivacyError(
      `${where} produced ${text.length} characters, over the ${limit} cap. ` +
        'Narrow the window, aggregate it, or lower the row limit.',
    );
  }

  return value;
}

/// Trims a list to [limit] and says so, rather than silently dropping the tail.
///
/// A model told it received 20 of 63 sessions can ask for a narrower window. A
/// model handed 20 and told nothing concludes there were 20.
export function capped<T>(
  rows: T[],
  limit: number,
): { rows: T[]; total: number; truncated: boolean } {
  return {
    rows: rows.slice(0, limit),
    total: rows.length,
    truncated: rows.length > limit,
  };
}

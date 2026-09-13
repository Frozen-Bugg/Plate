import type { ModelClient } from '../model/client.ts';
import type { CoachData } from '../data.ts';
import { assertMinimal } from '../privacy.ts';
import { buildSnapshot } from '../snapshot.ts';

/// The two moments the coach speaks without being asked.
///
/// A brief when a session opens, a debrief when one is finished. Both are
/// listed as low effort in docs/PLAN.md §7 and both are deliberately short:
/// nobody reads three paragraphs standing at a rack, and a debrief that
/// outlasts the walk to the car is a debrief nobody finishes.
///
/// No tools. Both run from the snapshot, which already carries the engine's
/// next targets, the recent sessions and the recovery signals — that is what
/// the snapshot is for, and a tool loop here would add seconds to a screen
/// somebody is waiting on.

export type BriefKind = 'brief' | 'debrief';

const briefPrompt = `
You are writing the note a lifter reads in the thirty seconds before they
start training.

Three sentences at most. No greeting, no sign-off, no bullet points.

Say, in this order, only what is worth saying:

- What the engine has queued today, if anything stands out — a lift that is
  stalled, a load that is a jump, a first session back.
- One thing about how they are placed: sleep, readiness, a hard session two
  days ago, being deep in a deficit. Only if it should change how they train.
- Nothing else. No encouragement, no "let's crush it", no restating the plan.

If there is nothing useful to say, say one sentence about what is queued and
stop. A short note that is true beats a long one that is padding.

Never state a number you were not given.
`.trim();

const debriefPrompt = `
You are writing the note a lifter reads just after finishing a session.

Three sentences at most. No greeting, no sign-off.

Say, in this order, only what is worth saying:

- What actually happened that matters: a PR, a lift that moved after stalling,
  a session cut short, volume well above or below usual.
- What it means for next time, if anything. The engine sets the loads; you say
  what to watch.
- Nothing else. Do not congratulate, do not summarise what they already know
  they did.

If the session was ordinary, say so in one sentence. Not every workout has a
story, and inventing one for every session is how a coach stops being read.

Never state a number you were not given.
`.trim();

export interface BriefInput {
  data: CoachData;
  today: string;
  kind: BriefKind;
  /// What was just done, for a debrief. Kept out of the snapshot because the
  /// session may not have reached the rollup yet.
  justDid?: string;
}

/// Writes a brief or a debrief. Returns empty when there is nothing to say.
export async function writeBrief(
  model: ModelClient,
  input: BriefInput,
): Promise<string> {
  const snapshot = await buildSnapshot({ data: input.data, today: input.today });

  const ask = input.kind === 'brief'
    ? 'Write the note for the session about to start.'
    : [
        'Write the note for the session just finished.',
        input.justDid ? `\nWhat was logged:\n${input.justDid.slice(0, 2000)}` : '',
      ].join('');

  const reply = await model.send({
    system: `${input.kind === 'brief' ? briefPrompt : debriefPrompt}\n\n## Where he is right now\n\n${snapshot}`,
    messages: [{ role: 'user', text: ask }],
    // Room for a reasoning model to think and still write. 400 was enough for
    // three sentences and not enough for three sentences *plus* the thinking
    // that precedes them, so the brief came back empty — a 200 carrying
    // nothing, which is the hardest kind of failure to notice.
    maxOutputTokens: 1024,
    effort: 'low',
  });

  return assertMinimal(tidy(reply.text), `${input.kind}`);
}

/// Trims the habits a short note cannot afford.
///
/// Models open with "Here's your brief:" and close with an offer to help, and
/// both waste a line of the three this has. Stripping them is cheaper than
/// arguing with the prompt.
function tidy(text: string): string {
  return text
    .replace(/^\s*(here(?:'s| is)[^:\n]*:|brief:|debrief:)\s*/i, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

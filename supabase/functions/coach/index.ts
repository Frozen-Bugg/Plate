// The Coach API, as a Supabase Edge Function.
//
// A thin edge: parse the request, build the context, run the loop, stream the
// answer. Everything with logic in it lives in ../../../coach-api/src, which is
// where the tests are — this file is the part that cannot be unit-tested
// without deploying, so there is deliberately as little of it as possible.
//
// Two things it does not do.
//
// **It does not write to the database.** The device owns writes: the app saves
// both turns to `coach_messages` locally and PowerSync carries them up, the
// same path a logged set takes. One write path is why chat history works
// offline and survives a failed request.
//
// **It does not trust the caller's identity.** `verify_jwt` is on by default, so
// the platform has already checked the token; the token is then forwarded to
// PostgREST so RLS decides what can be read. Nothing here filters by user id,
// because nothing here should be trusted to.

import { runAgent } from '../../../coach-api/src/agent.ts';
import { SupabaseData } from '../../../coach-api/src/data.ts';
import { guardTrainingTier, modelFrom } from '../../../coach-api/src/model/index.ts';
import { systemFor } from '../../../coach-api/src/prompt.ts';
import { writeBrief } from '../../../coach-api/src/tools/briefs.ts';
import { draftPrepPlan, draftRecipe } from '../../../coach-api/src/tools/draft.ts';
import { estimateFoods } from '../../../coach-api/src/tools/estimate.ts';
import { suggestMeals } from '../../../coach-api/src/tools/suggest.ts';
import { ParseError, parseMeal, parsePhoto, parseSets } from '../../../coach-api/src/tools/parse.ts';
import { buildSnapshot } from '../../../coach-api/src/snapshot.ts';
import { readTools } from '../../../coach-api/src/tools/read.ts';
import type { Turn } from '../../../coach-api/src/model/client.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface AskBody {
  message: string;
  /// Prior turns of this thread, oldest first. The device holds the history —
  /// see the note above about who writes.
  history?: { role: 'user' | 'assistant'; text: string }[];
  /// The lifter's local calendar day. Sent by the device because the day
  /// boundary is theirs, not the server's.
  today?: string;
  /// How hard to think. Chat is medium; a brief is low.
  effort?: 'low' | 'medium' | 'high';
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response(null, { headers: cors });
  }
  if (request.method !== 'POST') {
    return fail(405, 'Send a POST.');
  }

  const jwt = request.headers.get('Authorization')?.replace(/^Bearer /i, '');
  if (!jwt) return fail(401, 'No credentials.');

  let body: AskBody & {
    text?: string;
    slot?: string;
    image?: string;
    mediaType?: string;
    kind?: string;
    justDid?: string;
    names?: string[];
  };
  try {
    body = await request.json();
  } catch {
    return fail(400, 'Body was not JSON.');
  }

  // Several routes, one function. Everything but the chat is a single model
  // call with one right answer — no tools, no history, low effort — so each
  // gets its own path rather than being bolted onto the conversation as a tool
  // the conversation would then want to discuss.
  const path = new URL(request.url).pathname;
  const chosen = () => modelFrom(Deno.env.toObject());

  if (path.endsWith('/parse-food')) {
    return oneShot(() => parseMeal(chosen(), body.text ?? '', { slot: body.slot }));
  }
  if (path.endsWith('/parse-sets')) {
    return oneShot(() => parseSets(chosen(), body.text ?? ''));
  }
  if (path.endsWith('/parse-photo')) {
    return oneShot(() =>
      parsePhoto(
        chosen(),
        { mediaType: body.mediaType ?? '', data: body.image ?? '' },
        { slot: body.slot, note: body.text },
      )
    );
  }
  if (path.endsWith('/brief')) return brief(body, jwt);
  if (path.endsWith('/suggest')) return suggest(body, jwt);
  if (path.endsWith('/draft-recipe')) {
    return oneShot(() => draftRecipe(chosen(), body.text ?? ''));
  }
  if (path.endsWith('/draft-plan')) return plan(body, jwt);
  if (path.endsWith('/estimate-foods')) {
    return oneShot(() => estimateFoods(chosen(), body.names ?? []));
  }

  const message = (body.message ?? '').trim();
  if (!message) return fail(400, 'Nothing to answer.');

  const env = Deno.env.toObject();

  let model;
  try {
    // Refuses real data on a tier that may train on it, unless opted into.
    // Checked before any query runs, so nothing is read that cannot be used.
    guardTrainingTier(env, { synthetic: false });
    model = modelFrom(env);
  } catch (error) {
    // A misconfiguration, not the lifter's fault. Say which one plainly: this
    // is the message that turns "the coach is broken" into a one-line fix.
    return fail(503, message_of(error));
  }

  const data = new SupabaseData(
    env.SUPABASE_URL!,
    env.SUPABASE_ANON_KEY!,
    jwt,
  );

  const today = /^\d{4}-\d{2}-\d{2}$/.test(body.today ?? '')
    ? body.today!
    : new Date().toISOString().slice(0, 10);

  const messages: Turn[] = [
    ...(body.history ?? []).slice(-20).map((turn) =>
      turn.role === 'assistant'
        ? ({ role: 'assistant', text: turn.text } as const)
        : ({ role: 'user', text: turn.text } as const)
    ),
    { role: 'user', text: message },
  ];

  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    async start(controller) {
      const send = (event: string, payload: unknown) => {
        controller.enqueue(
          encoder.encode(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`),
        );
      };

      try {
        const snapshot = await buildSnapshot({ data, today });

        const result = await runAgent(
          model,
          {
            system: systemFor(snapshot),
            tools: readTools({ data, today }),
            messages,
            effort: body.effort ?? 'medium',
          },
          (chunk) => send('delta', { text: chunk }),
        );

        send('done', {
          text: result.text,
          chips: result.chips,
          model: result.model,
          stop: result.stop,
          usage: result.usage,
        });
      } catch (error) {
        // A failed turn is reported, never swallowed. The device stores it on
        // the message row and shows it, for the same reason a dropped upload
        // is recorded rather than discarded.
        send('failed', { message: message_of(error) });
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      ...cors,
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
    },
  });
});

/// One model call, one JSON answer.
///
/// Every parse route has the same shape: check the training-tier guard, run
/// the parse, hand back a proposal. Nothing here writes — docs/PLAN.md §11
/// requires an estimate to be shown itemised and editable and never logged on
/// the model's say-so, so the device confirms and the device saves.
///
/// Plain JSON rather than SSE: there is nothing to stream, and a parse that
/// half-arrives is no use to anyone.
async function oneShot(parse: () => Promise<unknown>): Promise<Response> {
  try {
    guardTrainingTier(Deno.env.toObject(), { synthetic: false });
    return new Response(JSON.stringify(await parse()), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    // 422 is the parser saying the input was not what it needed, and its
    // message is written for the lifter to act on. Anything else is ours.
    return fail(error instanceof ParseError ? 422 : 503, message_of(error));
  }
}

/// The note before a session, or after one.
///
/// Reads the lifter's own data, so unlike the parses it needs their token.
/// "What should I eat?" — three options, none of them logged.
///
/// Reads rather than writes, so it needs the lifter's JWT and the training
/// tier guard, same as the brief. Everything numeric is worked out here; the
/// model is asked only which combinations are a good idea.
async function suggest(
  body: { today?: string; note?: string },
  jwt: string,
): Promise<Response> {
  const env = Deno.env.toObject();

  try {
    guardTrainingTier(env, { synthetic: false });
    const data = new SupabaseData(env.SUPABASE_URL!, env.SUPABASE_ANON_KEY!, jwt);
    const result = await suggestMeals(modelFrom(env), {
      data,
      today: /^d{4}-d{2}-d{2}$/.test(body.today ?? '')
        ? body.today!
        : new Date().toISOString().slice(0, 10),
      note: body.note,
    });
    return new Response(JSON.stringify(result), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    return fail(503, message_of(error));
  }
}

/// A week of cooking, drafted around what is already in the fridge.
///
/// Reads, so it needs the JWT and the training tier guard. The fridge and the
/// recipe names are gathered here rather than asked of the model, which is
/// told only what exists and asked only what to do about it.
async function plan(
  body: { today?: string; note?: string },
  jwt: string,
): Promise<Response> {
  const env = Deno.env.toObject();

  try {
    guardTrainingTier(env, { synthetic: false });
    const data = new SupabaseData(env.SUPABASE_URL!, env.SUPABASE_ANON_KEY!, jwt);
    const today = /^d{4}-d{2}-d{2}$/.test(body.today ?? '')
      ? body.today!
      : new Date().toISOString().slice(0, 10);

    const [prep, recipes] = await Promise.all([
      data.prepOnHand(today),
      data.recipes(),
    ]);

    const onHand = prep.length === 0
      ? ''
      : `In the fridge:
${prep
        .map((batch) =>
          `- ${batch.name}: ${batch.servingsLeft} servings left` +
          (batch.daysLeft === undefined
            ? ''
            : batch.daysLeft <= 1
            ? ', must be eaten now'
            : `, keeps ${batch.daysLeft} more days`)
        )
        .join('\n')}`;

    const result = await draftPrepPlan(modelFrom(env), {
      onHand,
      recipes: recipes.map((recipe) => recipe.name),
      note: body.note,
    });
    return new Response(JSON.stringify(result), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    return fail(503, message_of(error));
  }
}

async function brief(
  body: { kind?: string; today?: string; justDid?: string },
  jwt: string,
): Promise<Response> {
  const env = Deno.env.toObject();

  try {
    guardTrainingTier(env, { synthetic: false });
    const data = new SupabaseData(env.SUPABASE_URL!, env.SUPABASE_ANON_KEY!, jwt);
    const text = await writeBrief(modelFrom(env), {
      data,
      today: /^\d{4}-\d{2}-\d{2}$/.test(body.today ?? '')
        ? body.today!
        : new Date().toISOString().slice(0, 10),
      kind: body.kind === 'debrief' ? 'debrief' : 'brief',
      justDid: body.justDid,
    });
    return new Response(JSON.stringify({ text }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    // A brief that cannot be written is not worth blocking a workout over, so
    // the device treats any failure here as "no note today".
    return fail(503, message_of(error));
  }
}

function fail(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

function message_of(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

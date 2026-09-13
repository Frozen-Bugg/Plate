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
import { ParseError, parseMeal } from '../../../coach-api/src/tools/parse.ts';
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

  let body: AskBody & { text?: string; slot?: string };
  try {
    body = await request.json();
  } catch {
    return fail(400, 'Body was not JSON.');
  }

  // Two routes, one function. Parsing a meal is not a conversation — one model
  // call, no tools, no history — so it gets its own path rather than being
  // bolted onto the chat as a tool the chat would then want to discuss.
  if (new URL(request.url).pathname.endsWith('/parse-food')) {
    return parseFood(body, jwt);
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

/// "4 eggs and 2 high protein sandwiches" → itemised numbers, for confirmation.
///
/// Returns a proposal and writes nothing. docs/PLAN.md §11: an estimate is
/// shown itemised and editable, and is never logged on the model's say-so.
/// Plain JSON rather than SSE — there is nothing to stream, and a parse that
/// half-arrives is no use.
async function parseFood(
  body: { text?: string; slot?: string },
  _jwt: string,
): Promise<Response> {
  const env = Deno.env.toObject();

  try {
    guardTrainingTier(env, { synthetic: false });
    const meal = await parseMeal(modelFrom(env), body.text ?? '', {
      slot: body.slot,
    });
    return new Response(JSON.stringify(meal), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    // A parse that failed is the lifter's to see and retry, in their own words.
    return fail(error instanceof ParseError ? 422 : 503, message_of(error));
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

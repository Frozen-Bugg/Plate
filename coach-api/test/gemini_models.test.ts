import assert from 'node:assert/strict';
import { test } from 'node:test';

import { GeminiClient } from '../src/model/gemini.ts';
import { nextModel, rankModels } from '../src/model/gemini_models.ts';
import type { ModelInfo } from '../src/model/gemini_models.ts';

/// The shape the listing endpoint returns.
const listing = (...names: string[]): ModelInfo[] =>
  names.map((name) => ({
    name: `models/${name}`,
    supportedGenerationMethods: ['generateContent'],
  }));

test('prefers Flash over Pro, because Pro is not free', () => {
  // Not a quality judgement. gemini-3.1-pro answered 429 with "limit: 0",
  // which on a free key is not a slower answer, it is no answer.
  const ranked = rankModels(listing('gemini-3.1-pro', 'gemini-2.5-flash'));
  assert.equal(ranked[0], 'gemini-2.5-flash');
});

test('prefers newer within a family', () => {
  const ranked = rankModels(
    listing('gemini-2.0-flash', 'gemini-2.5-flash', 'gemini-3-flash'),
  );
  assert.deepEqual(ranked, ['gemini-3-flash', 'gemini-2.5-flash', 'gemini-2.0-flash']);
});

test('prefers stable over preview', () => {
  // A preview is the next name to be retired, which is the whole problem.
  const ranked = rankModels(
    listing('gemini-3-flash-preview', 'gemini-2.5-flash'),
  );
  assert.equal(ranked[0], 'gemini-2.5-flash');
});

test('takes lite only when there is nothing else', () => {
  const ranked = rankModels(listing('gemini-2.5-flash-lite', 'gemini-2.5-flash'));
  assert.deepEqual(ranked, ['gemini-2.5-flash', 'gemini-2.5-flash-lite']);

  // But it is still an answer, and an answer beats none.
  assert.deepEqual(rankModels(listing('gemini-2.5-flash-lite')), [
    'gemini-2.5-flash-lite',
  ]);
});

test('ignores models that are not for talking to', () => {
  // The listing does not say what a model is *for*, and an image model
  // supports generateContent perfectly well.
  const ranked = rankModels(
    listing(
      'text-embedding-004',
      'imagen-3.0-generate',
      'veo-2.0',
      'gemini-2.5-flash-tts',
      'gemini-2.5-flash',
    ),
  );
  assert.deepEqual(ranked, ['gemini-2.5-flash']);
});

test('ignores models that cannot generate content at all', () => {
  const ranked = rankModels([
    { name: 'models/gemini-2.5-flash', supportedGenerationMethods: ['countTokens'] },
    { name: 'models/gemini-2.0-flash', supportedGenerationMethods: ['generateContent'] },
  ]);
  assert.deepEqual(ranked, ['gemini-2.0-flash']);
});

test('never suggests a model already known not to work', () => {
  const models = listing('gemini-2.5-flash', 'gemini-2.0-flash');
  assert.equal(nextModel(models, ['gemini-2.5-flash']), 'gemini-2.0-flash');
  assert.equal(
    nextModel(models, ['gemini-2.5-flash', 'gemini-2.0-flash']),
    undefined,
    'it kept suggesting models that had already failed',
  );
});

test('an empty listing suggests nothing rather than guessing', () => {
  assert.equal(nextModel([], []), undefined);
});

/// A fetch that fails for named models and answers for the rest.
function keyThatRefuses(dead: Record<string, { status: number; body: string }>) {
  const asked: string[] = [];
  const impl = (async (url: string | URL, init?: RequestInit) => {
    const target = String(url);

    if (target.endsWith('/v1beta/models')) {
      return new Response(
        JSON.stringify({
          models: [
            { name: 'models/gemini-3.1-pro', supportedGenerationMethods: ['generateContent'] },
            { name: 'models/gemini-2.5-flash', supportedGenerationMethods: ['generateContent'] },
            { name: 'models/gemini-2.0-flash', supportedGenerationMethods: ['generateContent'] },
          ],
        }),
        { status: 200 },
      );
    }

    const model = /models\/([^:]+):/.exec(target)?.[1] ?? '';
    asked.push(model);
    const refusal = dead[model];
    if (refusal) return new Response(refusal.body, { status: refusal.status });

    return new Response(
      `data: ${JSON.stringify({
        candidates: [{ content: { parts: [{ text: 'ok' }] }, finishReason: 'STOP' }],
      })}\n\n`,
      { status: 200, headers: { 'content-type': 'text/event-stream' } },
    );
  }) as unknown as typeof fetch;

  return { impl, asked };
}

const request = { system: 's', messages: [{ role: 'user' as const, text: 'hi' }] };

test('a retired model is replaced without anyone editing a constant', async () => {
  // Exactly what happened: "This model is no longer available to new users."
  const { impl, asked } = keyThatRefuses({
    'gemini-2.5-flash': {
      status: 404,
      body: '{"error":{"message":"no longer available to new users"}}',
    },
  });

  const client = new GeminiClient('k', 'gemini-2.5-flash', impl);
  const reply = await client.send(request);

  assert.equal(reply.text, 'ok');
  assert.equal(client.model, 'gemini-2.0-flash', 'did not move to a working model');
  assert.deepEqual(asked, ['gemini-2.5-flash', 'gemini-2.0-flash']);
});

test('a model with no free allowance is replaced too', async () => {
  // 429 with "limit: 0" means the model is real but costs money. Retrying it
  // forever is the wrong answer; so is treating it as a rate limit.
  const { impl } = keyThatRefuses({
    'gemini-2.5-flash': {
      status: 429,
      body: '{"error":{"message":"Quota exceeded ... free_tier_input_token_count, limit: 0"}}',
    },
  });

  const client = new GeminiClient('k', 'gemini-2.5-flash', impl);
  assert.equal((await client.send(request)).text, 'ok');
  assert.equal(client.model, 'gemini-2.0-flash');
});

test('a spent daily quota moves to a model with its own allowance', async () => {
  // The free tier's request cap is per model, not per key — one name answered
  // 429 "limit: 20" while another answered 503 in the same minute. So the free
  // tier is not twenty requests a day; it is twenty per Flash model, and this
  // is what makes the rest of them reachable.
  const { impl } = keyThatRefuses({
    'gemini-2.5-flash': {
      status: 429,
      body: '{"error":{"message":"Quota exceeded ... free_tier_requests, limit: 20"}}',
    },
  });

  const client = new GeminiClient('k', 'gemini-2.5-flash', impl);
  assert.equal((await client.send(request)).text, 'ok');
  assert.equal(client.model, 'gemini-2.0-flash');
});

test('when every model is out of quota it is still worth retrying later', async () => {
  // Distinct from a 404: a quota resets, so the caller should try again rather
  // than treat the coach as broken.
  const { impl } = keyThatRefuses({
    'gemini-2.5-flash': { status: 429, body: 'limit: 20' },
    'gemini-2.0-flash': { status: 429, body: 'limit: 20' },
    'gemini-3.1-pro': { status: 429, body: 'limit: 20' },
  });

  const client = new GeminiClient('k', 'gemini-2.5-flash', impl);
  const failed = await client.send(request).catch((e) => e);
  assert.equal(failed.retryable, true);
});

test('a model named deliberately is never swapped out', async () => {
  // Someone who set COACH_MODEL wants that model. Silently answering from
  // another one is worse than saying the chosen one does not work.
  const { impl } = keyThatRefuses({
    'gemini-2.5-flash': { status: 404, body: '{"error":{"message":"gone"}}' },
  });

  const client = new GeminiClient('k', 'gemini-2.5-flash', impl, undefined, {
    pinned: true,
  });
  const failed = await client.send(request).catch((e) => e);

  assert.match(failed.message, /404 for gemini-2.5-flash/);
  assert.equal(client.model, 'gemini-2.5-flash');
});

test('when nothing works it says so instead of looping', async () => {
  const { impl, asked } = keyThatRefuses({
    'gemini-2.5-flash': { status: 404, body: 'gone' },
    'gemini-2.0-flash': { status: 404, body: 'gone' },
    'gemini-3.1-pro': { status: 404, body: 'gone' },
  });

  const client = new GeminiClient('k', 'gemini-2.5-flash', impl);
  const failed = await client.send(request).catch((e) => e);

  assert.match(failed.message, /404/);
  // Each candidate tried exactly once.
  assert.equal(new Set(asked).size, asked.length, 'a model was tried twice');
  assert.ok(asked.length <= 3);
});

test('ranks the models this key actually reports', () => {
  // The real listing, read out of the error the API produced. Regression cover
  // for the ranking against something other than an invented fixture.
  const real = listing(
    'gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.5-flash-preview-tts',
    'gemma-4-31b-it', 'gemini-flash-latest', 'gemini-flash-lite-latest',
    'gemini-pro-latest', 'gemini-2.5-flash-lite', 'gemini-2.5-flash-image',
    'gemini-3-flash-preview', 'gemini-3.1-pro-preview', 'gemini-3.1-flash-lite',
    'gemini-3-pro-image', 'nano-banana-pro-preview', 'gemini-3.5-flash',
    'gemini-3.5-flash-lite', 'gemini-3.6-flash', 'gemini-3.7-flash',
    'gemini-3.8-flash', 'gemini-3.5-transcribe', 'lyria-3.5',
  );

  const ranked = rankModels(real);

  // Newest stable Flash wins.
  assert.equal(ranked[0], 'gemini-3.8-flash');
  assert.deepEqual(ranked.slice(0, 4), [
    'gemini-3.8-flash', 'gemini-3.7-flash', 'gemini-3.6-flash', 'gemini-3.5-flash',
  ]);

  // Pro is never picked over Flash: it has no free allowance.
  const firstPro = ranked.findIndex((m) => /pro/.test(m));
  const lastFlash = ranked.map((m) => /flash/.test(m)).lastIndexOf(true);
  assert.ok(firstPro > lastFlash, 'a Pro model outranked a Flash one');

  // Nothing that is not for chatting.
  for (const name of ranked) {
    assert.match(name, /^gemini-/, 'a non-Gemini product got in');
    assert.doesNotMatch(name, /tts|image|transcribe/);
  }
});

test('an overloaded model is swapped, not waited out', async () => {
  // "This model is currently experiencing high demand" is about one model, not
  // about the key. The free tier's popular names are the contended ones, and a
  // different Flash model is usually idle — so switching beats waiting.
  const { impl } = keyThatRefuses({
    'gemini-2.5-flash': {
      status: 503,
      body: '{"error":{"message":"This model is currently experiencing high demand.","status":"UNAVAILABLE"}}',
    },
  });

  const client = new GeminiClient('k', 'gemini-2.5-flash', impl);
  assert.equal((await client.send(request)).text, 'ok');
  assert.equal(client.model, 'gemini-2.0-flash');
});

test('an overloaded pinned model is reported, not swapped', async () => {
  const { impl } = keyThatRefuses({
    'gemini-2.5-flash': { status: 503, body: '{"error":{"message":"high demand"}}' },
  });

  const client = new GeminiClient('k', 'gemini-2.5-flash', impl, undefined, {
    pinned: true,
  });
  const failed = await client.send(request).catch((e) => e);

  assert.match(failed.message, /503 for gemini-2.5-flash/);
  // Still worth one retry: demand spikes pass.
  assert.equal(failed.retryable, true);
});

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { AnthropicClient } from '../src/model/anthropic.ts';
import {
  dataMayTrainModels,
  guardTrainingTier,
  modelFrom,
} from '../src/model/index.ts';

test('defaults to the provider that runs for free', () => {
  const model = modelFrom({ GEMINI_API_KEY: 'k' });
  assert.equal(model.model, 'gemini-2.5-flash');
});

test('switching provider is one environment variable', () => {
  // The whole promise of the abstraction: no code change, no rebuild of the
  // tools, the snapshot or the loop.
  const model = modelFrom({
    COACH_PROVIDER: 'anthropic',
    ANTHROPIC_API_KEY: 'k',
  });
  assert.equal(model.model, 'claude-opus-5');
});

test('the model itself can be pinned without touching code', () => {
  // Model names change faster than this repo will. Anything current can be
  // named here rather than waiting for a release.
  assert.equal(
    modelFrom({ GEMINI_API_KEY: 'k', COACH_MODEL: 'gemini-3-pro' }).model,
    'gemini-3-pro',
  );
});

test('a missing key says which one and where to get it', () => {
  assert.throws(() => modelFrom({}), /GEMINI_API_KEY.*aistudio\.google\.com/s);
  assert.throws(
    () => modelFrom({ COACH_PROVIDER: 'anthropic' }),
    /ANTHROPIC_API_KEY.*console\.anthropic\.com/s,
  );
});

test('an unknown provider names the ones that exist', () => {
  assert.throws(
    () => modelFrom({ COACH_PROVIDER: 'wishful' }),
    /Unknown COACH_PROVIDER "wishful".*gemini, anthropic/s,
  );
});

test('knows which providers may train on what they are sent', () => {
  assert.equal(dataMayTrainModels('gemini'), true);
  assert.equal(dataMayTrainModels('anthropic'), false);
});

test('refuses to send real data to a tier that may train on it', () => {
  // The concern that outlives the bill. A lifter's weight, sleep and photos
  // going into someone's training set cannot be undone later.
  assert.throws(
    () => guardTrainingTier({ GEMINI_API_KEY: 'k' }, { synthetic: false }),
    /may use what is sent to it to train models/,
  );
});

test('the eval suite may use the free tier, because nobody there is real', () => {
  guardTrainingTier({ GEMINI_API_KEY: 'k' }, { synthetic: true });
});

test('a provider that does not train needs no permission', () => {
  guardTrainingTier(
    { COACH_PROVIDER: 'anthropic', ANTHROPIC_API_KEY: 'k' },
    { synthetic: false },
  );
});

test('an explicit opt-in is honoured, and has to be explicit', () => {
  guardTrainingTier(
    { GEMINI_API_KEY: 'k', COACH_ALLOW_TRAINING_TIER: 'true' },
    { synthetic: false },
  );
  // Anything other than a deliberate "true" is not consent.
  for (const value of ['TRUE', '1', 'yes', '']) {
    assert.throws(
      () =>
        guardTrainingTier(
          { GEMINI_API_KEY: 'k', COACH_ALLOW_TRAINING_TIER: value },
          { synthetic: false },
        ),
      /train models/,
      `"${value}" was taken as consent`,
    );
  }
});

test('DeepSeek runs on its Anthropic-format endpoint, not its OpenAI one', async () => {
  // Their own docs: the Chat Completions API "does not support inserting tool
  // calls mid-conversation", which is exactly what an agent loop does on every
  // step after the first. The Anthropic-format endpoint does support it, takes
  // x-api-key, and is driven by the adapter that already exists.
  const sent: { url: string; headers: Record<string, string>; body: any }[] = [];
  const impl = (async (url: string | URL, init?: RequestInit) => {
    sent.push({
      url: String(url),
      headers: (init?.headers ?? {}) as Record<string, string>,
      body: JSON.parse(String(init?.body ?? '{}')),
    });
    return new Response(
      'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n',
      { status: 200, headers: { 'content-type': 'text/event-stream' } },
    );
  }) as unknown as typeof fetch;

  const client = new AnthropicClient(
    'k',
    'deepseek-flash',
    impl,
    'https://api.deepseek.com/anthropic',
    { name: 'DeepSeek', effort: false },
  );
  await client.send({
    system: 's',
    messages: [{ role: 'user', text: 'hi' }],
    effort: 'high',
  });

  assert.equal(sent[0].url, 'https://api.deepseek.com/anthropic/v1/messages');
  assert.equal(sent[0].headers['x-api-key'], 'k');
  assert.equal(sent[0].body.model, 'deepseek-flash');
  // `output_config` is Anthropic's own field. An unknown field is a 400 more
  // often than it is ignored.
  assert.ok(!('output_config' in sent[0].body), 'sent an Anthropic-only field');
});

test('a DeepSeek failure says DeepSeek, not Anthropic', async () => {
  // Same wire format, different service. An error naming the wrong vendor sends
  // whoever reads it to the wrong dashboard.
  const impl = (async () =>
    new Response('{"error":{"message":"insufficient balance"}}', {
      status: 402,
    })) as unknown as typeof fetch;

  const failed = await new AnthropicClient(
    'k',
    'deepseek-flash',
    impl,
    'https://api.deepseek.com/anthropic',
    { name: 'DeepSeek' },
  )
    .send({ system: 's', messages: [{ role: 'user', text: 'hi' }] })
    .catch((e) => e);

  assert.match(failed.message, /DeepSeek has no balance left/);
  assert.match(failed.message, /stops rather than running up a bill/);
  // Retrying does not add money.
  assert.equal(failed.retryable, false);
});

test('DeepSeek is built from one environment variable like the others', () => {
  const model = modelFrom({ COACH_PROVIDER: 'deepseek', DEEPSEEK_API_KEY: 'k' });
  assert.equal(model.model, 'deepseek-flash');

  assert.throws(
    () => modelFrom({ COACH_PROVIDER: 'deepseek' }),
    /DEEPSEEK_API_KEY.*platform\.deepseek\.com/s,
  );
});

test('DeepSeek is treated as a tier that may train on what it is sent', () => {
  // Trains by default with an opt-out, and stores inputs in China with no
  // published retention window. The second is not what this flag measures, but
  // both are reasons a real lifter's data should not go there by accident.
  assert.equal(dataMayTrainModels('deepseek'), true);
  assert.throws(
    () =>
      guardTrainingTier(
        { COACH_PROVIDER: 'deepseek', DEEPSEEK_API_KEY: 'k' },
        { synthetic: false },
      ),
    /may use what is sent to it to train models/,
  );
});

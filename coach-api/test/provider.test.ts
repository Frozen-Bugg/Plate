import assert from 'node:assert/strict';
import { test } from 'node:test';

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

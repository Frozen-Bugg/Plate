import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { CoachData } from '../src/data.ts';
import { StubClient } from '../src/model/stub.ts';
import { writeBrief } from '../src/tools/briefs.ts';

const today = '2026-09-13';

function fake(overrides: Partial<CoachData> = {}): CoachData {
  return {
    profile: async () => ({ phase: 'cut' }),
    days: async () => [],
    targetOn: async () => null,
    progression: async () => [
      { exercise: 'Bench Press', nextLoadKg: 87.5, nextReps: 6, stallCount: 3 },
    ],
    sessions: async () => [],
    setsFor: async () => [],
    meals: async () => [],
    exerciseNames: async () => [],
    volumeByMuscle: async () => [],
    foodNames: async () => [],
    recipes: async () => [],
    prepOnHand: async () => [],
    memories: async () => [],
    ...overrides,
  };
}

test('a brief runs from the snapshot and calls no tools', async () => {
  // Somebody is standing at a rack waiting for this. A tool loop would add
  // seconds to a screen that has to open instantly.
  const model = new StubClient([{ text: 'Bench is queued at 87.5 for 6.' }]);
  await writeBrief(model, { data: fake(), today, kind: 'brief' });

  assert.equal(model.lastRequest.tools, undefined);
  assert.equal(model.requests.length, 1);
  assert.equal(model.lastRequest.effort, 'low');
});

test('the brief carries the engine targets it is meant to mention', async () => {
  const model = new StubClient([{ text: 'ok' }]);
  await writeBrief(model, { data: fake(), today, kind: 'brief' });

  assert.match(model.lastRequest.system, /Bench Press: 87\.5kg x 6/);
  assert.match(model.lastRequest.system, /stalled 3/);
});

test('a brief and a debrief are given different instructions', async () => {
  const brief = new StubClient([{ text: 'ok' }]);
  await writeBrief(brief, { data: fake(), today, kind: 'brief' });

  const debrief = new StubClient([{ text: 'ok' }]);
  await writeBrief(debrief, { data: fake(), today, kind: 'debrief' });

  assert.match(brief.lastRequest.system, /before they\s+start training/);
  assert.match(debrief.lastRequest.system, /just after finishing/);
  assert.notEqual(brief.lastRequest.system, debrief.lastRequest.system);
});

test('a debrief is told what was just done', async () => {
  // The session may not have reached the rollup yet, so it cannot come from
  // the snapshot.
  const model = new StubClient([{ text: 'ok' }]);
  await writeBrief(model, {
    data: fake(),
    today,
    kind: 'debrief',
    justDid: 'Bench Press 87.5kg x 6, 6, 5',
  });

  assert.match((model.lastMessages[0] as { text: string }).text, /87\.5kg x 6/);
});

test('leaves room to think and still write', async () => {
  // The cap has to hold three sentences *plus* whatever reasoning precedes
  // them. At 400 it held the reasoning and not the sentences, and the brief
  // came back empty.
  const model = new StubClient([{ text: 'ok' }]);
  await writeBrief(model, { data: fake(), today, kind: 'brief' });
  const cap = model.lastRequest.maxOutputTokens ?? 0;
  assert.ok(cap >= 1024, 'too tight for a reasoning model');
  assert.ok(cap <= 2048, 'a brief is three sentences, not an essay');
});

test('strips the preamble a short note cannot afford', async () => {
  for (const opener of [
    "Here's your brief: Bench is queued.",
    'Here is the note: Bench is queued.',
    'Brief: Bench is queued.',
  ]) {
    const text = await writeBrief(new StubClient([{ text: opener }]), {
      data: fake(),
      today,
      kind: 'brief',
    });
    assert.equal(text, 'Bench is queued.', `did not strip: ${opener}`);
  }
});

test('leaves an ordinary answer alone', async () => {
  const text = await writeBrief(
    new StubClient([{ text: 'Bench has not moved in three sessions.' }]),
    { data: fake(), today, kind: 'brief' },
  );
  assert.equal(text, 'Bench has not moved in three sessions.');
});

test('refuses to put an identifier in a brief', async () => {
  await assert.rejects(
    () =>
      writeBrief(
        new StubClient([
          { text: 'See session 3f7c1a2e-9b4d-4c1f-8a2e-1d2c3b4a5f60.' },
        ]),
        { data: fake(), today, kind: 'debrief' },
      ),
    /uuid/,
  );
});

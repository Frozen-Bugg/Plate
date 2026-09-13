import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { CoachData } from '../src/data.ts';
import { StubClient } from '../src/model/stub.ts';
import { suggestMeals } from '../src/tools/suggest.ts';

const today = '2026-09-13';

function fake(overrides: Partial<CoachData> = {}): CoachData {
  return {
    profile: async () => null,
    days: async () => [],
    targetOn: async () => ({
      from: today,
      kcal: 2180,
      proteinG: 174,
      carbG: 200,
      fatG: 65,
      source: 'engine',
    }),
    progression: async () => [],
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

const threeOptions = JSON.stringify({
  options: [
    { name: 'Beef chilli', kcal: 584, proteinG: 41, carbG: 38, fatG: 26, why: 'It needs eating today.', fromPrep: 'Beef chilli' },
    { name: 'Chicken rice bowl', kcal: 612, proteinG: 52, carbG: 64, fatG: 15, why: 'Closes the protein gap.', fromRecipe: 'Chicken rice bowl' },
    { name: 'Greek yoghurt and whey', kcal: 300, proteinG: 40, carbG: 20, fatG: 5, why: 'Small, and mostly protein.' },
  ],
});

const lunch = {
  day: today,
  slot: 'lunch',
  food: 'Chicken salad',
  quantityG: 400,
  kcal: 610,
  proteinG: 55,
  carbG: 30,
  fatG: 26,
};

test('the arithmetic is done here and handed over', async () => {
  // The model is asked what would be a good idea, never what is left.
  const model = new StubClient([{ text: threeOptions }]);
  const result = await suggestMeals(model, {
    data: fake({ meals: async () => [lunch] }),
    today,
  });

  assert.equal(result.logged.kcal, 610);
  assert.equal(result.left?.kcal, 1570);
  assert.equal(result.left?.proteinG, 119);
  assert.match((model.lastMessages[0] as { text: string }).text, /Left today: 1570 kcal, P119/);
});

test('no tools, one call, low effort', async () => {
  // A parse with one right answer. A model that can call something will.
  const model = new StubClient([{ text: threeOptions }]);
  await suggestMeals(model, { data: fake(), today });

  assert.equal(model.lastRequest.tools, undefined);
  assert.equal(model.requests.length, 1);
  assert.equal(model.lastRequest.effort, 'low');
});

test('the fridge is described with its deadlines', async () => {
  const model = new StubClient([{ text: threeOptions }]);
  const result = await suggestMeals(model, {
    data: fake({
      prepOnHand: async () => [
        {
          name: 'Beef chilli',
          cookedOn: '2026-09-11',
          servingsLeft: 2,
          perServing: { kcal: 584, proteinG: 41, carbG: 38, fatG: 26 },
          daysLeft: 1,
        },
        {
          name: 'Overnight oats',
          cookedOn: '2026-09-13',
          servingsLeft: 3,
          perServing: { kcal: 320, proteinG: 22, carbG: 40, fatG: 8 },
          daysLeft: 4,
        },
      ],
    }),
    today,
  });

  const sent = (model.lastMessages[0] as { text: string }).text;
  assert.match(sent, /Beef chilli: 2 servings left, 584 kcal and P41 each, must be eaten by tomorrow/);
  assert.match(sent, /Overnight oats.*keeps 4 more days/);
  // And the device is told too, so it can say it without waiting on the model.
  assert.match(result.urgent!, /Beef chilli — 2 servings left, eat it by tomorrow/);
});

test('an empty fridge says so rather than being left out', async () => {
  const model = new StubClient([{ text: threeOptions }]);
  await suggestMeals(model, { data: fake(), today });
  assert.match((model.lastMessages[0] as { text: string }).text, /Nothing cooked in the fridge/);
  assert.match((model.lastMessages[0] as { text: string }).text, /No saved recipes/);
});

test('no target is a different answer from nothing left', async () => {
  const model = new StubClient([{ text: threeOptions }]);
  const result = await suggestMeals(model, {
    data: fake({ targetOn: async () => null }),
    today,
  });

  assert.equal(result.left, undefined);
  assert.equal(result.target, undefined);
  assert.match((model.lastMessages[0] as { text: string }).text, /No calorie target is set/);
});

test('options carry where they came from, so the device can log them', async () => {
  const model = new StubClient([{ text: threeOptions }]);
  const result = await suggestMeals(model, { data: fake(), today });

  assert.equal(result.options.length, 3);
  assert.equal(result.options[0]?.fromPrep, 'Beef chilli');
  assert.equal(result.options[1]?.fromRecipe, 'Chicken rice bowl');
  assert.equal(result.options[2]?.fromPrep, undefined);
  assert.equal(result.options[2]?.fromRecipe, undefined);
});

test('what the lifter said is passed along', async () => {
  const model = new StubClient([{ text: threeOptions }]);
  await suggestMeals(model, {
    data: fake(),
    today,
    note: 'I have got chicken, rice and spinach in',
  });
  assert.match((model.lastMessages[0] as { text: string }).text, /They said: I have got chicken/);
});

test('a nameless option is dropped rather than shown blank', async () => {
  const model = new StubClient([{
    text: JSON.stringify({
      options: [
        { name: '', kcal: 400, why: 'nothing' },
        { name: 'Eggs on toast', kcal: 420, proteinG: 24, carbG: 40, fatG: 18, why: 'Quick.' },
      ],
    }),
  }]);
  const result = await suggestMeals(model, { data: fake(), today });
  assert.equal(result.options.length, 1);
  assert.equal(result.options[0]?.name, 'Eggs on toast');
});

test('a missing calorie count is zero, not a crash', async () => {
  const model = new StubClient([{
    text: JSON.stringify({ options: [{ name: 'Eggs', why: 'Quick.' }] }),
  }]);
  const result = await suggestMeals(model, { data: fake(), today });
  assert.equal(result.options[0]?.kcal, 0);
});

test('an answer with nothing usable in it throws', async () => {
  for (const text of ['not json at all', '{"options":[]}', '{"nope":1}']) {
    await assert.rejects(
      () => suggestMeals(new StubClient([{ text }]), { data: fake(), today }),
      /suggestion|think of anything|read/i,
      `accepted: ${text}`,
    );
  }
});

test('refuses to put an identifier in a suggestion', async () => {
  await assert.rejects(
    () =>
      suggestMeals(
        new StubClient([{
          text: JSON.stringify({
            options: [{
              name: 'Batch 3f7c1a2e-9b4d-4c1f-8a2e-1d2c3b4a5f60',
              kcal: 500,
              why: 'It is there.',
            }],
          }),
        }]),
        { data: fake(), today },
      ),
    /uuid/,
  );
});

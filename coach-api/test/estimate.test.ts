import assert from 'node:assert/strict';
import { test } from 'node:test';

import { StubClient } from '../src/model/stub.ts';
import { estimateFoods } from '../src/tools/estimate.ts';

const chicken = JSON.stringify({
  foods: [
    {
      name: 'Chicken breast',
      kcalPer100: 165,
      proteinPer100: 31,
      carbPer100: 0,
      fatPer100: 3.6,
      note: 'raw, skinless',
    },
    {
      name: 'White rice',
      kcalPer100: 360,
      proteinPer100: 7,
      carbPer100: 79,
      fatPer100: 0.7,
      note: 'dry, uncooked',
    },
  ],
});

test('prices a list of ingredients per 100 g', async () => {
  const foods = await estimateFoods(
    new StubClient([{ text: chicken }]),
    ['Chicken breast', 'White rice'],
  );

  assert.equal(foods.length, 2);
  assert.equal(foods[0]?.kcalPer100, 165);
  assert.equal(foods[0]?.proteinPer100, 31);
  assert.equal(foods[0]?.note, 'raw, skinless');
  assert.equal(foods[1]?.note, 'dry, uncooked');
});

test('one call for the whole list, not one each', async () => {
  // Eight unmatched ingredients would otherwise be eight round trips with
  // somebody watching a spinner.
  const model = new StubClient([{ text: chicken }]);
  await estimateFoods(model, ['Chicken breast', 'White rice']);

  assert.equal(model.requests.length, 1);
  assert.equal(model.lastRequest.tools, undefined);
  assert.equal(model.lastRequest.effort, 'low');
  assert.match(
    (model.lastMessages[0] as { text: string }).text,
    /Chicken breast\nWhite rice/,
  );
});

test('the name is echoed back exactly, because it is the join key', async () => {
  const model = new StubClient([{ text: chicken }]);
  await estimateFoods(model, ['Chicken breast']);
  assert.match(model.lastRequest.system, /echoed back \*\*exactly\*\*/);
});

test('nothing edible is over 900 kcal per 100 g', async () => {
  // Past that it is a per-serving figure or a slip, and either way the schema
  // would reject it after quietly wrecking the recipe.
  const foods = await estimateFoods(
    new StubClient([{
      text: JSON.stringify({
        foods: [
          { name: 'Olive oil', kcalPer100: 884, proteinPer100: 0, carbPer100: 0, fatPer100: 100 },
          { name: 'Rice', kcalPer100: 1800, proteinPer100: 7, carbPer100: 79, fatPer100: 1 },
        ],
      }),
    }]),
    ['Olive oil', 'Rice'],
  );

  assert.equal(foods.length, 1);
  assert.equal(foods[0]?.name, 'Olive oil');
});

test('a macro per 100 g cannot exceed 100 g, or be negative', async () => {
  const foods = await estimateFoods(
    new StubClient([{
      text: JSON.stringify({
        foods: [{
          name: 'Whey',
          kcalPer100: 400,
          proteinPer100: 480,
          carbPer100: -5,
          fatPer100: 7,
        }],
      }),
    }]),
    ['Whey'],
  );

  assert.equal(foods[0]?.proteinPer100, 100);
  assert.equal(foods[0]?.carbPer100, 0);
});

test('something that is not a food is left out rather than invented', async () => {
  await assert.rejects(
    () =>
      estimateFoods(
        new StubClient([{ text: '{"foods":[]}' }]),
        ['Bin bags'],
      ),
    /could not price/i,
  );
});

test('an empty list is refused without a model call', async () => {
  const model = new StubClient([{ text: chicken }]);
  await assert.rejects(() => estimateFoods(model, ['  ', '']), /Nothing to look up/);
  assert.equal(model.requests.length, 0);
});

test('an unreadable answer throws rather than costing nothing', async () => {
  for (const text of ['not json', '{"nope":1}', '{"foods":"chicken"}']) {
    await assert.rejects(
      () => estimateFoods(new StubClient([{ text }]), ['Chicken']),
      /nutrition|read|price/i,
      `accepted: ${text}`,
    );
  }
});

test('refuses to put an identifier in an estimate', async () => {
  await assert.rejects(
    () =>
      estimateFoods(
        new StubClient([{
          text: JSON.stringify({
            foods: [{
              name: 'Food 3f7c1a2e-9b4d-4c1f-8a2e-1d2c3b4a5f60',
              kcalPer100: 100,
              proteinPer100: 1,
              carbPer100: 1,
              fatPer100: 1,
            }],
          }),
        }]),
        ['Chicken'],
      ),
    /uuid/,
  );
});

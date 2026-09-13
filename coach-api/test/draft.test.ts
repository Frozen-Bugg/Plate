import assert from 'node:assert/strict';
import { test } from 'node:test';

import { StubClient } from '../src/model/stub.ts';
import { draftRecipe } from '../src/tools/draft.ts';

const bowl = JSON.stringify({
  name: 'Chicken rice bowl',
  servings: 4,
  ingredients: [
    { name: 'Chicken breast', grams: 600, note: 'raw weight' },
    { name: 'White rice', grams: 300, note: 'dry' },
    { name: 'Olive oil', grams: 30 },
  ],
  method: 'Roast the chicken, boil the rice, combine.',
});

test('a recipe comes back as names and weights', async () => {
  const draft = await draftRecipe(
    new StubClient([{ text: bowl }]),
    'a chicken and rice thing for four lunches',
  );

  assert.equal(draft.name, 'Chicken rice bowl');
  assert.equal(draft.servings, 4);
  assert.equal(draft.ingredients.length, 3);
  assert.deepEqual(draft.ingredients[0], {
    name: 'Chicken breast',
    grams: 600,
    note: 'raw weight',
  });
  assert.match(draft.method!, /Roast the chicken/);
});

test('the model is told in so many words not to state a macro', async () => {
  // The point of the whole route. recipe_items.food_id is NOT NULL, so every
  // ingredient ends up costed from a real row — asking for a number here
  // could only produce a wrong one.
  const model = new StubClient([{ text: bowl }]);
  await draftRecipe(model, 'chicken and rice');

  assert.match(model.lastRequest.system, /Never state calories or macros/);
  assert.equal(model.lastRequest.tools, undefined);
  assert.equal(model.lastRequest.effort, 'low');
});

test('nothing in the shape carries a macro to begin with', async () => {
  // Belt and braces: if a model ignores the instruction, there is nowhere for
  // the number to go.
  const model = new StubClient([{
    text: JSON.stringify({
      name: 'Omelette',
      servings: 1,
      ingredients: [{ name: 'Eggs', grams: 150, kcal: 234, proteinG: 19 }],
    }),
  }]);
  const draft = await draftRecipe(model, 'omelette');

  assert.deepEqual(Object.keys(draft.ingredients[0]!), ['name', 'grams']);
});

test('an ingredient with no weight cannot be costed, so it is dropped', async () => {
  // Shown without a weight it would be silently left out of the total, which
  // is the quiet kind of wrong.
  const draft = await draftRecipe(
    new StubClient([{
      text: JSON.stringify({
        name: 'Stew',
        servings: 2,
        ingredients: [
          { name: 'Beef', grams: 500 },
          { name: 'Salt' },
          { name: 'Stock', grams: 0 },
        ],
      }),
    }]),
    'a stew',
  );

  assert.equal(draft.ingredients.length, 1);
  assert.equal(draft.ingredients[0]?.name, 'Beef');
});

test('servings falls back to one rather than to nonsense', async () => {
  for (const servings of [undefined, 0, -3, 'four', 500]) {
    const draft = await draftRecipe(
      new StubClient([{
        text: JSON.stringify({
          name: 'Porridge',
          servings,
          ingredients: [{ name: 'Oats', grams: 80 }],
        }),
      }]),
      'porridge',
    );
    assert.equal(draft.servings, 1, `servings: ${servings}`);
  }
});

test('an answer that is not a recipe throws rather than saving an empty one', async () => {
  for (const text of [
    'not json',
    '{"name":"","servings":1,"ingredients":[]}',
    '{"name":"Soup","servings":2,"ingredients":[]}',
    '{"nope":true}',
  ]) {
    await assert.rejects(
      () => draftRecipe(new StubClient([{ text }]), 'something'),
      /recipe|read/i,
      `accepted: ${text}`,
    );
  }
});

test('an empty description is refused without a model call', async () => {
  const model = new StubClient([{ text: bowl }]);
  await assert.rejects(() => draftRecipe(model, '   '), /Nothing to make/);
  assert.equal(model.requests.length, 0);
});

test('refuses to put an identifier in a recipe', async () => {
  await assert.rejects(
    () =>
      draftRecipe(
        new StubClient([{
          text: JSON.stringify({
            name: 'Recipe 3f7c1a2e-9b4d-4c1f-8a2e-1d2c3b4a5f60',
            servings: 1,
            ingredients: [{ name: 'Eggs', grams: 100 }],
          }),
        }]),
        'eggs',
      ),
    /uuid/,
  );
});

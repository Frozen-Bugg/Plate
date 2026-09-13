import assert from 'node:assert/strict';
import { test } from 'node:test';

import { StubClient } from '../src/model/stub.ts';
import { draftPrepPlan, draftRecipe } from '../src/tools/draft.ts';

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

// ---------------------------------------------------------------------------
// A week of cooking
// ---------------------------------------------------------------------------

const weekPlan = JSON.stringify({
  cooks: [
    { name: 'Chicken rice bowl', servings: 4, saved: true, ingredients: [], covers: 'Mon-Wed lunches' },
    {
      name: 'Beef chilli',
      servings: 3,
      saved: false,
      ingredients: [
        { name: 'Beef mince', grams: 500, note: '5% fat' },
        { name: 'Kidney beans', grams: 400 },
      ],
      covers: 'Thu-Sat lunches',
    },
  ],
  note: 'Sunday is left free.',
});

test('a saved recipe is named rather than re-invented', async () => {
  const plan = await draftPrepPlan(new StubClient([{ text: weekPlan }]), {
    onHand: '',
    recipes: ['Chicken rice bowl'],
  });

  const saved = plan.cooks[0]!;
  assert.equal(saved.saved, true);
  assert.equal(saved.name, 'Chicken rice bowl');
  // The device has the ingredients already, and a second copy would drift.
  assert.deepEqual(saved.ingredients, []);
  assert.equal(saved.covers, 'Mon-Wed lunches');
});

test('a new dish carries its ingredients and still no macros', async () => {
  const plan = await draftPrepPlan(new StubClient([{ text: weekPlan }]), {
    onHand: '',
    recipes: [],
  });

  const fresh = plan.cooks[1]!;
  assert.equal(fresh.saved, false);
  assert.equal(fresh.ingredients.length, 2);
  assert.deepEqual(Object.keys(fresh.ingredients[1]!), ['name', 'grams']);
});

test('the fridge is put in front of it, with the deadlines', async () => {
  const model = new StubClient([{ text: weekPlan }]);
  await draftPrepPlan(model, {
    onHand: 'In the fridge:\n- Beef chilli: 2 servings left, must be eaten now',
    recipes: ['Chicken rice bowl'],
    note: 'six lunches',
  });

  const sent = (model.lastMessages[0] as { text: string }).text;
  assert.match(sent, /Beef chilli: 2 servings left/);
  assert.match(sent, /Saved recipes: Chicken rice bowl/);
  assert.match(sent, /They said: six lunches/);
  assert.match(model.lastRequest.system, /Subtract what is already cooked/);
});

test('an empty fridge says so rather than being left out', async () => {
  const model = new StubClient([{ text: weekPlan }]);
  await draftPrepPlan(model, { onHand: '', recipes: [] });
  const sent = (model.lastMessages[0] as { text: string }).text;
  assert.match(sent, /Nothing cooked in the fridge/);
  assert.match(sent, /No saved recipes/);
});

test('a new dish with nothing in it is dropped', async () => {
  // It cannot be shopped for or cooked, and showing it would promise a meal
  // that does not exist.
  const plan = await draftPrepPlan(
    new StubClient([{
      text: JSON.stringify({
        cooks: [
          { name: 'Something', servings: 4, saved: false, ingredients: [] },
          { name: 'Porridge', servings: 4, saved: true, ingredients: [] },
        ],
      }),
    }]),
    { onHand: '', recipes: ['Porridge'] },
  );

  assert.equal(plan.cooks.length, 1);
  assert.equal(plan.cooks[0]?.name, 'Porridge');
});

test('a week with nothing to plan is not an error', async () => {
  // Everything covered by the fridge is a real answer, and throwing would make
  // the good outcome look like a failure.
  const plan = await draftPrepPlan(
    new StubClient([{ text: '{"cooks":[]}' }]),
    { onHand: 'loads', recipes: [] },
  );
  assert.deepEqual(plan.cooks, []);
});

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { StubClient } from '../src/model/stub.ts';
import { ParseError, parseMeal, parsePhoto, parseSets } from '../src/tools/parse.ts';

/// A model that answers with whatever text it is handed.
const saying = (text: string) => new StubClient([{ text }]);

const breakfast = JSON.stringify({
  slot: 'breakfast',
  items: [
    {
      name: 'Eggs',
      quantity: 4,
      unit: 'item',
      grams: 200,
      kcal: 312,
      proteinG: 25,
      carbG: 1,
      fatG: 22,
      note: 'assumed large',
    },
    {
      name: 'High protein sandwich',
      quantity: 2,
      unit: 'item',
      grams: 300,
      kcal: 640,
      proteinG: 48,
      carbG: 60,
      fatG: 22,
    },
  ],
});

test('splits a sentence into one entry per food', async () => {
  const meal = await parseMeal(
    saying(breakfast),
    'I had 4 eggs and 2 high protein sandwiches for breakfast',
  );

  assert.equal(meal.slot, 'breakfast');
  assert.equal(meal.items.length, 2);
  assert.equal(meal.items[0].name, 'Eggs');
  assert.equal(meal.items[0].quantity, 4);
  assert.equal(meal.items[0].grams, 200);
  assert.equal(meal.items[1].name, 'High protein sandwich');
});

test('keeps the assumption it made, so it can be argued with', async () => {
  const meal = await parseMeal(saying(breakfast), 'four eggs');
  assert.equal(meal.items[0].note, 'assumed large');
  // Nothing to say is better than a note saying nothing.
  assert.equal(meal.items[1].note, undefined);
});

test('takes the slot from the sentence over the one it was given', async () => {
  const meal = await parseMeal(saying(breakfast), 'eggs', { slot: 'dinner' });
  assert.equal(meal.slot, 'breakfast');
});

test('falls back to the slot the screen was on', async () => {
  const meal = await parseMeal(
    saying('{"slot":"nonsense","items":[]}'),
    'nothing',
    { slot: 'lunch' },
  );
  assert.equal(meal.slot, 'lunch');
});

test('reads JSON out of a fence, because models add them', async () => {
  const meal = await parseMeal(
    saying('Here you go:\n```json\n' + breakfast + '\n```'),
    'eggs',
  );
  assert.equal(meal.items.length, 2);
});

test('an empty sentence is refused before it costs a model call', async () => {
  const model = saying(breakfast);
  await assert.rejects(() => parseMeal(model, '   '), ParseError);
  assert.equal(model.requests.length, 0);
});

test('names no food, logs no food', async () => {
  // "I went to the gym" is not a meal, and inventing one to have something to
  // show would be the worst possible failure here.
  const meal = await parseMeal(saying('{"slot":"snack","items":[]}'), 'hello');
  assert.deepEqual(meal.items, []);
});

test('an item with no weight or no energy is dropped, not guessed at', async () => {
  // A silent zero reaching the rollup is worse than the item going missing,
  // because the total still looks like an answer.
  const meal = await parseMeal(
    saying(
      JSON.stringify({
        slot: 'snack',
        items: [
          { name: 'Air', quantity: 1, unit: 'item', grams: 0, kcal: 0 },
          { name: 'Rice', quantity: 1, unit: 'serving', grams: 180, kcal: 0 },
          { name: 'Banana', quantity: 1, unit: 'item', grams: 120, kcal: 105 },
        ],
      }),
    ),
    'stuff',
  );

  assert.deepEqual(meal.items.map((i) => i.name), ['Banana']);
});

test('an impossible portion is dropped', async () => {
  const meal = await parseMeal(
    saying(
      JSON.stringify({
        slot: 'snack',
        items: [{ name: 'Rice', quantity: 1, unit: 'g', grams: 90000, kcal: 500 }],
      }),
    ),
    'rice',
  );
  assert.deepEqual(meal.items, []);
});

test('flags an item whose macros do not add up to its calories', async () => {
  // 4/4/9. A model that says 300 kcal and 5 g of everything has guessed one of
  // the two, and the lifter should see which item to check rather than a
  // confident total.
  const meal = await parseMeal(
    saying(
      JSON.stringify({
        slot: 'snack',
        items: [
          {
            name: 'Protein bar',
            quantity: 1,
            unit: 'item',
            grams: 60,
            kcal: 300,
            proteinG: 5,
            carbG: 5,
            fatG: 1,
          },
        ],
      }),
    ),
    'a protein bar',
  );

  assert.match(meal.items[0].note ?? '', /macros do not add up/);
});

test('a negative or absurd macro becomes zero rather than reaching the database', async () => {
  const meal = await parseMeal(
    saying(
      JSON.stringify({
        slot: 'snack',
        items: [
          {
            name: 'Chicken',
            quantity: 1,
            unit: 'serving',
            grams: 150,
            kcal: 250,
            proteinG: -5,
            carbG: 'nonsense',
            fatG: 9,
          },
        ],
      }),
    ),
    'chicken',
  );

  assert.equal(meal.items[0].proteinG, 0);
  assert.equal(meal.items[0].carbG, 0);
  assert.equal(meal.items[0].fatG, 9);
});

test('refuses an answer that is not JSON at all', async () => {
  await assert.rejects(
    () => parseMeal(saying('I am not sure what you ate!'), 'eggs'),
    ParseError,
  );
});

test('refuses a shopping list', async () => {
  const many = {
    slot: 'snack',
    items: Array.from({ length: 25 }, (_, i) => ({
      name: `Food ${i}`,
      quantity: 1,
      unit: 'item',
      grams: 100,
      kcal: 100,
    })),
  };
  await assert.rejects(() => parseMeal(saying(JSON.stringify(many)), 'x'), ParseError);
});

test('asks for no tools, because a parse is not a conversation', async () => {
  const model = saying(breakfast);
  await parseMeal(model, 'eggs');

  assert.equal(model.lastRequest.tools, undefined);
  assert.equal(model.lastRequest.effort, 'low');
  // One call. Running this through the agent loop would cost two and invite
  // the model to chat about it.
  assert.equal(model.requests.length, 1);
});

test('refuses to send an identifier to the model', async () => {
  // Same rule as everywhere else: the parse result goes nowhere near a uuid.
  await assert.rejects(
    () =>
      parseMeal(
        saying(
          JSON.stringify({
            slot: 'snack',
            items: [
              {
                name: 'Food 3f7c1a2e-9b4d-4c1f-8a2e-1d2c3b4a5f60',
                quantity: 1,
                unit: 'item',
                grams: 100,
                kcal: 100,
              },
            ],
          }),
        ),
        'x',
      ),
    /uuid/,
  );
});

// ---------------------------------------------------------------------------
// Sets
// ---------------------------------------------------------------------------

const benchSets = JSON.stringify({
  sets: [
    { exercise: 'Bench Press', weightKg: 80, reps: 8, rir: 2, sets: 3 },
    { exercise: 'Barbell Row', weightKg: 70, reps: 10, sets: 1 },
  ],
});

test('reads sets, reps, load and effort out of a sentence', async () => {
  const sets = await parseSets(
    saying(benchSets),
    'three by eight at eighty on bench, RPE 8, then a set of ten rows at seventy',
  );

  assert.equal(sets.length, 2);
  assert.deepEqual(sets[0], {
    exercise: 'Bench Press',
    weightKg: 80,
    reps: 8,
    rir: 2,
    sets: 3,
  });
  // Effort is optional: a set logged without it is still a set.
  assert.equal(sets[1].rir, undefined);
  assert.equal(sets[1].sets, 1);
});

test('a set with no reps is not a set', async () => {
  const sets = await parseSets(
    saying(
      JSON.stringify({
        sets: [
          { exercise: 'Bench Press', weightKg: 80, reps: 0 },
          { exercise: 'Squat', weightKg: 100, reps: 5 },
        ],
      }),
    ),
    'stuff',
  );
  assert.deepEqual(sets.map((s) => s.exercise), ['Squat']);
});

test('zero load is legitimate, negative and absurd are not', async () => {
  // A pull-up is zero. 600 kg is a misheard number.
  const sets = await parseSets(
    saying(
      JSON.stringify({
        sets: [
          { exercise: 'Pull-up', weightKg: 0, reps: 8 },
          { exercise: 'Squat', weightKg: -20, reps: 5 },
          { exercise: 'Deadlift', weightKg: 900, reps: 1 },
        ],
      }),
    ),
    'stuff',
  );
  assert.deepEqual(sets.map((s) => s.exercise), ['Pull-up']);
});

test('an impossible RIR is dropped rather than logged', async () => {
  const sets = await parseSets(
    saying(
      JSON.stringify({
        sets: [{ exercise: 'Squat', weightKg: 100, reps: 5, rir: 40 }],
      }),
    ),
    'stuff',
  );
  assert.equal(sets[0].rir, undefined);
  assert.equal(sets[0].exercise, 'Squat');
});

test('no lifting described, nothing logged', async () => {
  assert.deepEqual(await parseSets(saying('{"sets":[]}'), 'I went for a walk'), []);
});

test('refuses a sentence that is not JSON', async () => {
  await assert.rejects(() => parseSets(saying('not sure'), 'bench'), ParseError);
});

test('set parsing asks for no tools either', async () => {
  const model = saying(benchSets);
  await parseSets(model, 'bench 80 for 8');
  assert.equal(model.lastRequest.tools, undefined);
  assert.equal(model.requests.length, 1);
});

// ---------------------------------------------------------------------------
// Photos
// ---------------------------------------------------------------------------

const jpeg = { mediaType: 'image/jpeg', data: 'aGVsbG8=' };

test('reads a plate into items, with what it assumed', async () => {
  const model = saying(
    JSON.stringify({
      slot: 'lunch',
      items: [
        {
          name: 'Grilled chicken breast',
          quantity: 1,
          unit: 'serving',
          grams: 180,
          kcal: 300,
          proteinG: 56,
          carbG: 0,
          fatG: 7,
          note: 'assumed no oil, plate about 26 cm',
        },
      ],
    }),
  );

  const meal = await parsePhoto(model, jpeg, { slot: 'lunch' });
  assert.equal(meal.items[0].name, 'Grilled chicken breast');
  assert.match(meal.items[0].note ?? '', /plate about 26 cm/);
});

test('the picture goes with the turn, before the text', async () => {
  // Both providers read a prompt that follows an image better than one that
  // precedes it.
  const model = saying('{"slot":"snack","items":[]}');
  await parsePhoto(model, jpeg);

  const turn = model.lastMessages[0];
  assert.equal(turn.role, 'user');
  assert.deepEqual((turn as { images?: unknown[] }).images, [jpeg]);
});

test('what the lifter said about the photo is passed on', async () => {
  // "the rice is half a cup" is the cheapest accuracy available.
  const model = saying('{"slot":"snack","items":[]}');
  await parsePhoto(model, jpeg, { note: 'the rice is about half a cup' });
  assert.match((model.lastMessages[0] as { text: string }).text, /half a cup/);
});

test('refuses something that is not a picture', async () => {
  await assert.rejects(
    () => parsePhoto(saying('{}'), { mediaType: 'application/pdf', data: 'x' }),
    ParseError,
  );
  await assert.rejects(
    () => parsePhoto(saying('{}'), { mediaType: 'image/jpeg', data: '' }),
    ParseError,
  );
});

test('refuses a photo that should have been resized on the device', async () => {
  await assert.rejects(
    () =>
      parsePhoto(saying('{}'), {
        mediaType: 'image/jpeg',
        data: 'a'.repeat(9_000_000),
      }),
    /too large/,
  );
});

test('a picture with no food in it logs nothing', async () => {
  const meal = await parsePhoto(saying('{"slot":"snack","items":[]}'), jpeg);
  assert.deepEqual(meal.items, []);
});

test('a photo estimate gets the same rails as a typed one', async () => {
  // Nothing about a camera makes an invented number more trustworthy.
  const meal = await parsePhoto(
    saying(
      JSON.stringify({
        slot: 'lunch',
        items: [
          { name: 'Mystery', quantity: 1, unit: 'serving', grams: 0, kcal: 200 },
          { name: 'Rice', quantity: 1, unit: 'serving', grams: 200, kcal: 260, proteinG: -4 },
        ],
      }),
    ),
    jpeg,
  );

  assert.deepEqual(meal.items.map((i) => i.name), ['Rice']);
  assert.equal(meal.items[0].proteinG, 0);
});

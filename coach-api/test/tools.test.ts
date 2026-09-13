import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { CoachData } from '../src/data.ts';
import { PrivacyError } from '../src/privacy.ts';
import { shiftDay } from '../src/snapshot.ts';
import { readTools } from '../src/tools/read.ts';

const today = '2026-09-13';

function fake(overrides: Partial<CoachData> = {}): CoachData {
  return {
    profile: async () => null,
    days: async () => [],
    targetOn: async () => null,
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

const toolsOf = (data: CoachData) => {
  const map = new Map(readTools({ data, today }).map((t) => [t.name, t]));
  return (name: string) => {
    const tool = map.get(name);
    if (!tool) throw new Error(`no tool ${name}`);
    return tool;
  };
};

test('every read tool declares a schema a provider will accept', () => {
  // Gemini rejects unknown keywords outright rather than ignoring them, so a
  // tool with a sloppy schema takes the whole turn down.
  for (const tool of readTools({ data: fake(), today })) {
    assert.equal(tool.parameters.type, 'object', `${tool.name} is not an object`);
    assert.ok(tool.description.length > 30, `${tool.name} is under-described`);
    for (const [name, schema] of Object.entries(tool.parameters.properties ?? {})) {
      assert.ok(
        ['string', 'number', 'integer', 'boolean', 'array'].includes(schema.type),
        `${tool.name}.${name} has type ${schema.type}`,
      );
    }
    for (const required of tool.parameters.required ?? []) {
      assert.ok(
        tool.parameters.properties?.[required],
        `${tool.name} requires ${required} but does not declare it`,
      );
    }
  }
});

test('a window is a word, not a date the model has to format', async () => {
  let asked = '';
  const tool = toolsOf(fake({
    sessions: async (from) => {
      asked = from;
      return [];
    },
  }))('query_training');

  await tool.run({ window: 'month' });
  assert.equal(asked, shiftDay(today, -30));

  await tool.run({});
  assert.equal(asked, shiftDay(today, -14), 'default is a fortnight');

  // A window the model invents must not become NaN days ago.
  await tool.run({ window: 'since forever' });
  assert.equal(asked, shiftDay(today, -14));
});

test('an empty log says it is empty rather than returning nothing', async () => {
  // The distinction that stops the coach announcing a fast that never happened.
  const result = (await toolsOf(fake())('query_nutrition').run({})) as any;
  assert.match(result.summary, /Nothing logged/);
  assert.match(result.summary, /missing data, not a fast/);
});

test('query_nutrition counts logged days against elapsed days', async () => {
  const days = Array.from({ length: 7 }, (_, i) => ({
    day: shiftDay(today, -i),
    intakeKcal: i < 3 ? 2200 : undefined,
    proteinG: i < 3 ? 170 : undefined,
  }));

  const result = (await toolsOf(fake({ days: async () => days }))(
    'query_nutrition',
  ).run({})) as any;

  assert.equal(result.days.length, 3);
  assert.match(result.summary, /3 of 7 days logged/);
});

test('query_nutrition only fetches foods when asked', async () => {
  let mealsCalled = 0;
  const data = fake({
    meals: async () => {
      mealsCalled++;
      return [];
    },
  });

  await toolsOf(data)('query_nutrition').run({});
  assert.equal(mealsCalled, 0, 'fetched every food for a summary question');

  await toolsOf(data)('query_nutrition').run({ detail: true });
  assert.equal(mealsCalled, 1);
});

test('query_sets insists on an exercise instead of returning everything', async () => {
  await assert.rejects(
    () => toolsOf(fake())('query_sets').run({}),
    /needs an exercise name/,
  );
});

test('query_sets points at search_exercises when the name misses', async () => {
  // The likeliest failure is a near-miss name, and the recovery is one tool
  // call away if the model is told.
  const result = (await toolsOf(fake())('query_sets').run({
    exercise: 'Bench Pres',
  })) as any;
  assert.match(result.summary, /check the name with search_exercises/i);
});

test('get_progression_status names what is stalled', async () => {
  const result = (await toolsOf(
    fake({
      progression: async () => [
        { exercise: 'Squat', nextLoadKg: 120, stallCount: 0 },
        { exercise: 'Bench Press', nextLoadKg: 85, stallCount: 4 },
        { exercise: 'Overhead Press', nextLoadKg: 50, stallCount: 3 },
      ],
    }),
  )('get_progression_status').run({})) as any;

  assert.match(result.summary, /2 stalled: Bench Press, Overhead Press/);
});

test('get_progression_status says so when nothing is stalled', async () => {
  const result = (await toolsOf(
    fake({ progression: async () => [{ exercise: 'Squat', nextLoadKg: 120 }] }),
  )('get_progression_status').run({})) as any;
  assert.match(result.summary, /none stalled/);
});

test('volume by muscle admits the counting is not additive', async () => {
  const tool = toolsOf(
    fake({
      volumeByMuscle: async () => [
        { muscle: 'chest', hardSets: 12, volumeKg: 4100 },
        { muscle: 'triceps', hardSets: 12, volumeKg: 4100 },
      ],
    }),
  )('get_volume_by_muscle');

  // A set counted once per muscle would otherwise read as double the work.
  assert.match(tool.description, /do not sum to the session total/);
  const result = (await tool.run({})) as any;
  assert.equal(result.muscles.length, 2);
});

test('search_exercises returns exact names to use elsewhere', async () => {
  const result = (await toolsOf(
    fake({
      exerciseNames: async () => ['Bench Press', 'Incline Bench Press', 'Squat'],
    }),
  )('search_exercises').run({ match: 'bench' })) as any;

  assert.deepEqual(result.exercises, ['Bench Press', 'Incline Bench Press']);
});

test('search_exercises suggests the app when a movement is missing', async () => {
  const result = (await toolsOf(fake({ exerciseNames: async () => ['Squat'] }))(
    'search_exercises',
  ).run({ match: 'zercher' })) as any;
  assert.match(result.summary, /can add it in the app/);
});

test('recall is there so the coach does not re-propose a refusal', async () => {
  const tool = toolsOf(
    fake({
      memories: async () => [
        { content: 'Declined a deload in March — competition', kind: 'decline', weight: 3 },
      ],
    }),
  )('recall');

  assert.match(tool.description, /already have said no to/);
  const result = (await tool.run({})) as any;
  assert.equal(result.memories.length, 1);
});

test('a big result is trimmed and says it was trimmed', async () => {
  // A model handed 20 rows and told nothing concludes there were 20.
  const sets = Array.from({ length: 400 }, (_, i) => ({
    day: today,
    exercise: 'Bench Press',
    weightKg: 80,
    reps: 5,
    isPr: false,
  }));

  const result = (await toolsOf(fake({ setsFor: async () => sets }))(
    'query_sets',
  ).run({ exercise: 'Bench Press' })) as any;

  assert.equal(result.sets.length, 120);
  assert.equal(result.truncated, true);
  assert.match(result.summary, /400 sets/);
});

test('a tool refuses to hand an identifier to the model', async () => {
  // The rule holds at the tool boundary too, not just in the snapshot.
  await assert.rejects(
    () =>
      toolsOf(
        fake({
          exerciseNames: async () => [
            'Squat (3f7c1a2e-9b4d-4c1f-8a2e-1d2c3b4a5f60)',
          ],
        }),
      )('search_exercises').run({ match: 'squat' }),
    PrivacyError,
  );
});

test('every tool answers with a summary the chips can show', async () => {
  // docs/PLAN.md §7 renders tool calls as "Checked 6 weeks of bench sessions".
  const data = fake();
  for (const tool of readTools({ data, today })) {
    const args = tool.parameters.required?.length
      ? Object.fromEntries(tool.parameters.required.map((k) => [k, 'squat']))
      : {};
    const result = (await tool.run(args)) as any;
    assert.equal(typeof result.summary, 'string', `${tool.name} has no summary`);
    assert.ok(result.summary.length > 0, `${tool.name} summarised as empty`);
  }
});

// ---------------------------------------------------------------------------
// What is left today, what is in the fridge (docs/MEAL-PLANNING.md §5)
// ---------------------------------------------------------------------------

const meal = (over: Partial<{
  kcal: number; proteinG: number; carbG: number; fatG: number;
}> = {}) => ({
  day: today,
  slot: 'lunch',
  food: 'Chicken',
  quantityG: 200,
  kcal: 330,
  proteinG: 62,
  carbG: 0,
  fatG: 7,
  ...over,
});

const target = {
  from: today,
  kcal: 2180,
  proteinG: 174,
  carbG: 200,
  fatG: 65,
  source: 'engine',
};

test('the remaining budget is subtraction, done here', async () => {
  // Never a model's job: the log knows, and a coach that is right about this
  // 99 times out of 100 is one nobody can rely on.
  const tools = toolsOf(fake({
    targetOn: async () => target,
    meals: async () => [meal(), meal({ kcal: 400, proteinG: 20, carbG: 60 })],
  }));

  const result = await tools('get_remaining_today').run({}) as {
    left: { kcal: number; proteinG: number };
    logged: { kcal: number };
    summary: string;
  };

  assert.equal(result.logged.kcal, 730);
  assert.equal(result.left.kcal, 2180 - 730);
  assert.equal(result.left.proteinG, 174 - 82);
  assert.match(result.summary, /1450 kcal and 92g protein left/);
});

test('a whole day untouched says so rather than reciting zeroes', async () => {
  const tools = toolsOf(fake({ targetOn: async () => target }));
  const result = await tools('get_remaining_today').run({}) as {
    summary: string;
    left: { kcal: number };
  };

  assert.match(result.summary, /Nothing logged today/);
  assert.equal(result.left.kcal, 2180);
});

test('no target means nothing is left, not that everything is', async () => {
  const tools = toolsOf(fake({ meals: async () => [meal()] }));
  const result = await tools('get_remaining_today').run({}) as {
    summary: string;
    left?: unknown;
  };

  assert.equal(result.left, undefined);
  assert.match(result.summary, /No calorie target is set/);
  assert.match(result.summary, /330 kcal logged/);
});

test('an empty fridge does not claim the cupboards are bare', async () => {
  // The app only knows about food that was logged as a cook. Saying there is
  // nothing to eat would be a claim it cannot make.
  const tools = toolsOf(fake());
  const result = await tools('get_prep_on_hand').run({}) as { summary: string };

  assert.match(result.summary, /Nothing cooked and waiting/);
  assert.match(result.summary, /says nothing about what is in the cupboard/);
});

test('the fridge leads with what is about to go off', async () => {
  const tools = toolsOf(fake({
    prepOnHand: async () => [
      {
        name: 'Beef chilli',
        cookedOn: '2026-09-12',
        servingsLeft: 2,
        perServing: { kcal: 584, proteinG: 41, carbG: 38, fatG: 26 },
        daysLeft: 1,
      },
      {
        name: 'Chicken rice bowl',
        cookedOn: '2026-09-13',
        servingsLeft: 3,
        perServing: { kcal: 612, proteinG: 52, carbG: 64, fatG: 15 },
        daysLeft: 4,
      },
    ],
  }));

  const result = await tools('get_prep_on_hand').run({}) as {
    summary: string;
    batches: { name: string }[];
  };

  assert.equal(result.batches[0]?.name, 'Beef chilli');
  assert.match(result.summary, /2 batches in the fridge, 1 needing eating/);
});

test('searching recipes filters by name and says what was searched', async () => {
  const tools = toolsOf(fake({
    recipes: async () => [
      { name: 'Chicken rice bowl', servings: 4, perServing: { kcal: 612, proteinG: 52, carbG: 64, fatG: 15 } },
      { name: 'Beef chilli', servings: 4, perServing: { kcal: 584, proteinG: 41, carbG: 38, fatG: 26 } },
    ],
  }));

  const found = await tools('search_recipes').run({ match: 'chicken' }) as {
    recipes: { name: string }[];
    summary: string;
  };
  assert.equal(found.recipes.length, 1);
  assert.match(found.summary, /1 of 2 saved recipes/);

  const missed = await tools('search_recipes').run({ match: 'lasagne' }) as {
    summary: string;
  };
  assert.match(missed.summary, /None of the 2 saved recipes match "lasagne"/);
});

test('no saved recipes is not a reason to refuse a suggestion', async () => {
  const tools = toolsOf(fake());
  const result = await tools('search_recipes').run({}) as { summary: string };
  assert.match(result.summary, /Suggesting one is still fine/);
});

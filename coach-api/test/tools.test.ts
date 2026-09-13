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

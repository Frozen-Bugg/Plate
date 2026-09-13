import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { CoachData, Day } from '../src/data.ts';
import { PrivacyError, assertMinimal } from '../src/privacy.ts';
import { buildSnapshot, shiftDay } from '../src/snapshot.ts';

/// An in-memory stand-in for the database, so the snapshot can be tested
/// without a project, a network or a seeded account.
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

/// A run of days ending today, losing weight steadily.
function cuttingDays(today: string, count = 14): Day[] {
  return Array.from({ length: count }, (_, i) => ({
    day: shiftDay(today, -i),
    trendWeightKg: 80 + i * 0.08,
    steps: 9000 - i * 100,
    sleepMinutes: 430,
    readiness: 70,
    intakeKcal: 2200,
    proteinG: 170,
    tdeeEst: 2650,
    phase: 'cut',
  }));
}

const today = '2026-09-13';

test('says what day it is', async () => {
  // The model has no clock, and "last Tuesday" is unanswerable without this.
  const text = await buildSnapshot({ data: fake(), today });
  assert.match(text, /Today is 2026-09-13\./);
});

test('is honest about an empty account rather than silent', async () => {
  const text = await buildSnapshot({ data: fake(), today });
  assert.match(text, /Target: none set\./);
  assert.match(text, /Intake: nothing logged/);
  assert.match(text, /no finished sessions/);
});

test('carries the numbers a coach actually reasons from', async () => {
  const text = await buildSnapshot({
    data: fake({
      profile: async () => ({
        experience: 'novice',
        phase: 'cut',
        heightCm: 172,
        birthYear: 2002,
        sex: 'male',
      }),
      days: async () => cuttingDays(today),
      targetOn: async () => ({
        from: '2026-09-01',
        kcal: 2158,
        proteinG: 182,
        carbG: 209,
        fatG: 66,
        source: 'engine',
        tdeeKcal: 2650,
      }),
    }),
    today,
  });

  assert.match(text, /Lifter: novice, male, 24y, 172cm\./);
  assert.match(text, /Goal: cut\./);
  assert.match(text, /Trend weight: 80\.0kg/);
  assert.match(text, /Target: 2158kcal, P182 C209 F66 \(engine\)\./);
  assert.match(text, /Intake: 2200kcal\/day over 7 logged of last 7, P170\./);
  assert.match(text, /TDEE estimate: 2650kcal\./);
});

test('reports the direction the scale is going', async () => {
  const text = await buildSnapshot({
    data: fake({ days: async () => cuttingDays(today) }),
    today,
  });
  // 0.08 kg/day lighter as the days get newer → about 0.56 kg a week lost.
  assert.match(text, /−0\.5[0-9]kg\/week/);
});

test('says the rate is not knowable yet rather than inventing one', async () => {
  // Two weigh-ins three days apart is noise, not a trend. docs/PLAN.md §5 gives
  // the real rule to the engine; the snapshot must not pre-empt it with a
  // number that looks authoritative.
  const text = await buildSnapshot({
    data: fake({
      days: async () => [
        { day: today, trendWeightKg: 80.0 },
        { day: shiftDay(today, -3), trendWeightKg: 80.9 },
      ],
    }),
    today,
  });
  assert.match(text, /rate needs more weigh-ins/);
});

test('never hides an injury behind a summary', async () => {
  // The one field that must survive every attempt to make this shorter.
  const text = await buildSnapshot({
    data: fake({
      profile: async () => ({
        injuries: 'Left shoulder — no overhead pressing until December',
      }),
    }),
    today,
  });
  assert.match(text, /Injuries\/limits: Left shoulder — no overhead pressing/);
});

test('shows recent sessions but not every session', async () => {
  const sessions = Array.from({ length: 9 }, (_, i) => ({
    day: shiftDay(today, -i),
    minutes: 52,
    exercises: ['Bench Press', 'Barbell Row'],
    sets: 6,
    volumeKg: 3000,
    prs: i === 0 ? 1 : 0,
  }));

  const text = await buildSnapshot({ data: fake({ sessions: async () => sessions }), today });

  assert.match(text, /Training: 9 sessions in 14d, 54 sets, last on 2026-09-13\./);
  // Four detailed, the rest a tool call away — that is the whole design.
  assert.equal(text.match(/ — 6 sets, 3000kg/g)?.length, 4);
  assert.match(text, /, 1 PR/);
});

test('leads with the lifts that matter and flags a stall', async () => {
  const text = await buildSnapshot({
    data: fake({
      progression: async () => [
        { exercise: 'Lateral Raise', nextLoadKg: 12, nextReps: 12, bestE1rmKg: 15 },
        { exercise: 'Squat', nextLoadKg: 120, nextReps: 5, bestE1rmKg: 140, stallCount: 4 },
      ],
    }),
    today,
  });

  const squat = text.indexOf('Squat:');
  const raise = text.indexOf('Lateral Raise:');
  assert.ok(squat !== -1 && raise !== -1);
  assert.ok(squat < raise, 'the heaviest lift should come first');
  assert.match(text, /Squat: 120kg x 5 — stalled 4/);
});

test('says whose numbers these are, so the coach does not claim them', async () => {
  // docs/PLAN.md: the engine owns the numbers; the coach displays or proposes.
  const text = await buildSnapshot({
    data: fake({
      progression: async () => [{ exercise: 'Squat', nextLoadKg: 120, nextReps: 5 }],
    }),
    today,
  });
  assert.match(text, /set by the engine, not by you/);
});

test('stays inside its token budget on a full account', async () => {
  // A snapshot that outgrows the cap means something is being pasted in that
  // should have been a tool call.
  const text = await buildSnapshot({
    data: fake({
      profile: async () => ({
        experience: 'intermediate',
        phase: 'cut',
        heightCm: 172,
        birthYear: 2002,
        sex: 'male',
        equipment: ['barbell', 'dumbbell', 'machine', 'cable', 'bands'],
        injuries: 'Left shoulder, right knee on deep flexion',
      }),
      days: async () => cuttingDays(today),
      targetOn: async () => ({
        from: '2026-09-01',
        kcal: 2158,
        proteinG: 182,
        carbG: 209,
        fatG: 66,
        source: 'engine',
      }),
      sessions: async () =>
        Array.from({ length: 12 }, (_, i) => ({
          day: shiftDay(today, -i),
          minutes: 62,
          exercises: ['Bench Press', 'Barbell Row', 'Overhead Press', 'Chin-up'],
          sets: 18,
          volumeKg: 9400,
          prs: 1,
        })),
      progression: async () =>
        Array.from({ length: 30 }, (_, i) => ({
          exercise: `Movement number ${i}`,
          nextLoadKg: 100 - i,
          nextReps: 5,
          bestE1rmKg: 140 - i,
        })),
    }),
    today,
  });

  assert.ok(text.length < 3000, `snapshot was ${text.length} chars`);
});

test('refuses to send an identifier to the model', async () => {
  // The rule the lifter asked for, enforced rather than intended. A uuid in a
  // prompt is a join key for whoever ends up holding the logs.
  await assert.rejects(
    () =>
      buildSnapshot({
        data: fake({
          profile: async () => ({
            injuries: 'see case 3f7c1a2e-9b4d-4c1f-8a2e-1d2c3b4a5f60',
          }),
        }),
        today,
      }),
    PrivacyError,
  );
});

test('refuses an email address wherever it turns up', () => {
  assert.throws(
    () => assertMinimal({ note: 'ask aakif@example.com' }, 'a tool'),
    /an email address/,
  );
});

test('refuses anything shaped like a key or token', () => {
  for (const secret of [
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N',
    'AIzaSyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI',
  ]) {
    assert.throws(() => assertMinimal(secret, 'a tool'), /token or key/);
  }
});

test('refuses a result too big to be an answer', () => {
  assert.throws(
    () => assertMinimal('x'.repeat(20_000), 'a tool'),
    /over the 16000 cap/,
  );
});

test('lets ordinary coaching text through untouched', () => {
  const payload = { exercise: 'Bench Press', e1rm: 82.5, day: '2026-09-13' };
  assert.equal(assertMinimal(payload, 'a tool'), payload);
});

test('shiftDay walks the calendar, month ends included', () => {
  assert.equal(shiftDay('2026-09-13', -14), '2026-08-30');
  assert.equal(shiftDay('2026-03-01', -1), '2026-02-28');
  assert.equal(shiftDay('2026-12-31', 1), '2027-01-01');
});

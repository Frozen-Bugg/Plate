import type { Tool } from '../agent.ts';
import type { CoachData } from '../data.ts';
import { emptyWindow } from '../phrasing.ts';
import { assertMinimal, capped } from '../privacy.ts';
import { shiftDay } from '../snapshot.ts';

/// The read half of docs/PLAN.md §7's tool list.
///
/// All of them are parallel-safe — nothing here writes, so the loop can run a
/// whole step's worth at once. The write tools (`log_food`, `log_sets`,
/// `remember`) and the `propose_*` family are deliberately not here yet: a tool
/// that changes data needs the approval path and the engine's validation in
/// front of it, and half of that is worse than none.
///
/// Two rules every tool below follows.
///
/// **Return what answers the question, not what is in the table.** A coach
/// asking about bench press does not need the squat sets, and a model handed
/// them reads the answer worse.
///
/// **Say what is missing.** "No sessions in that window" and "you have logged
/// nothing" are different facts, and a tool that returns `[]` for both lets the
/// coach state the wrong one confidently.

export interface ToolContext {
  data: CoachData;
  /// The lifter's local calendar day. Every window is measured back from here.
  today: string;
}

/// How far back a tool will look, by name, so the model does not have to guess
/// a date format.
const windows: Record<string, number> = {
  week: 7,
  fortnight: 14,
  month: 30,
  quarter: 90,
};

const windowArg = {
  type: 'string' as const,
  description: 'How far back to look. Defaults to fortnight.',
  enum: Object.keys(windows),
};

function since(context: ToolContext, window: unknown): string {
  const days = windows[String(window ?? 'fortnight')] ?? 14;
  return shiftDay(context.today, -days);
}

export function readTools(context: ToolContext): Tool[] {
  return [
    {
      name: 'query_training',
      description:
        'Finished workouts in a window: what was trained, how many sets, ' +
        'volume and PRs. Use this for "how has my training been" questions. ' +
        'For one exercise over time, use query_sets instead.',
      parameters: {
        type: 'object',
        properties: { window: windowArg },
      },
      async run(args) {
        const from = since(context, args.window);
        const sessions = await context.data.sessions(from);
        const { rows, total, truncated } = capped(sessions, 20);
        return assertMinimal(
          {
            from,
            to: context.today,
            sessions: rows,
            summary: total === 0
              ? emptyWindow('No finished workouts', from)
              : `${total} workouts since ${from}`,
            truncated,
          },
          'query_training',
        );
      },
    },

    {
      name: 'query_sets',
      description:
        'Every working set logged for one exercise, oldest first, with ' +
        'estimated one-rep max. This is how to answer "has my bench moved" or ' +
        '"am I stalling". Give the exercise name exactly as it appears in ' +
        'search_exercises.',
      parameters: {
        type: 'object',
        properties: {
          exercise: { type: 'string', description: 'Exercise name' },
          window: windowArg,
        },
        required: ['exercise'],
      },
      async run(args) {
        const exercise = String(args.exercise ?? '').trim();
        if (!exercise) throw new Error('query_sets needs an exercise name');

        const from = since(context, args.window ?? 'quarter');
        const sets = await context.data.setsFor(exercise, from);
        const { rows, total, truncated } = capped(sets, 120);

        return assertMinimal(
          {
            exercise,
            from,
            sets: rows,
            summary: total === 0
              ? `${emptyWindow(`No sets of ${exercise}`, from)} Check the name with search_exercises.`
              : `${total} sets of ${exercise} since ${from}`,
            truncated,
          },
          'query_sets',
        );
      },
    },

    {
      name: 'get_progression_status',
      description:
        'What the engine has decided to prescribe next for each exercise, ' +
        'and how many sessions it has been stalled. These numbers are the ' +
        "engine's; report them, do not recompute them.",
      parameters: { type: 'object', properties: {} },
      async run() {
        const progression = await context.data.progression();
        const stalled = progression.filter((p) => (p.stallCount ?? 0) >= 3);
        return assertMinimal(
          {
            exercises: capped(progression, 40).rows,
            summary: `${progression.length} exercises tracked` +
              (stalled.length
                ? `, ${stalled.length} stalled: ${stalled.map((s) => s.exercise).join(', ')}`
                : ', none stalled'),
          },
          'get_progression_status',
        );
      },
    },

    {
      name: 'get_volume_by_muscle',
      description:
        'Hard sets and volume per muscle in a window, for balance questions. ' +
        'A set is counted once for every muscle the exercise lists, so these ' +
        'do not sum to the session total. Muscles come from the exercise ' +
        'library; anything tagged "untagged" has no muscles recorded.',
      parameters: { type: 'object', properties: { window: windowArg } },
      async run(args) {
        const from = since(context, args.window ?? 'week');
        const muscles = await context.data.volumeByMuscle(from);
        return assertMinimal(
          {
            from,
            muscles,
            summary: muscles.length === 0
              ? emptyWindow('No working sets', from)
              : `${muscles.length} muscles trained since ${from}`,
          },
          'get_volume_by_muscle',
        );
      },
    },

    {
      name: 'query_nutrition',
      description:
        'Daily calories and protein against target. Set detail=true to also ' +
        'get the individual foods, which is only worth it for a few days at a ' +
        'time.',
      parameters: {
        type: 'object',
        properties: {
          window: windowArg,
          detail: {
            type: 'boolean',
            description: 'Include individual foods logged. Defaults to false.',
          },
        },
      },
      async run(args) {
        const from = since(context, args.window ?? 'week');
        const [days, target] = await Promise.all([
          context.data.days(from),
          context.data.targetOn(context.today),
        ]);

        const logged = days.filter((d) => d.intakeKcal !== undefined);
        const intake = logged.map((d) => ({
          day: d.day,
          kcal: d.intakeKcal,
          proteinG: d.proteinG,
        }));

        const detail = args.detail === true
          ? capped(await context.data.meals(from), 80).rows
          : undefined;

        return assertMinimal(
          {
            from,
            target,
            days: intake,
            foods: detail,
            // The distinction that stops the coach saying "you ate nothing".
            summary: logged.length === 0
              ? `${emptyWindow('Nothing logged', from)} That is missing data, not a fast.`
              : `${logged.length} of ${days.length} days logged since ${from}`,
          },
          'query_nutrition',
        );
      },
    },

    {
      name: 'query_body',
      description:
        'Weight, trend weight, steps, sleep and readiness by day. One row per ' +
        'day, already aggregated.',
      parameters: { type: 'object', properties: { window: windowArg } },
      async run(args) {
        const from = since(context, args.window);
        const days = await context.data.days(from);
        return assertMinimal(
          {
            from,
            days: capped(
              days.map((d) => ({
                day: d.day,
                weightKg: d.weightKg,
                trendWeightKg: d.trendWeightKg,
                steps: d.steps,
                sleepMinutes: d.sleepMinutes,
                readiness: d.readiness,
              })),
              60,
            ).rows,
            summary: days.length === 0
              ? emptyWindow('No days recorded', from)
              : `${days.length} days since ${from}`,
          },
          'query_body',
        );
      },
    },

    {
      name: 'search_exercises',
      description:
        'Find a movement by name before using it in another tool or a ' +
        'proposal. Matches loosely; returns the exact names to use.',
      parameters: {
        type: 'object',
        properties: {
          match: { type: 'string', description: 'Part of the name' },
        },
        required: ['match'],
      },
      async run(args) {
        const match = String(args.match ?? '').trim().toLowerCase();
        const names = await context.data.exerciseNames();
        const hits = match
          ? names.filter((n) => n.toLowerCase().includes(match))
          : names;
        const { rows, total } = capped(hits, 40);
        return assertMinimal(
          {
            exercises: rows,
            summary: total === 0
              ? `Nothing matching "${match}". The lifter can add it in the app.`
              : `${total} matching "${match}"`,
          },
          'search_exercises',
        );
      },
    },

    {
      name: 'search_foods',
      description:
        "Find something in the lifter's own food list by name. Only foods " +
        'they have logged before are here.',
      parameters: {
        type: 'object',
        properties: {
          match: { type: 'string', description: 'Part of the name' },
        },
        required: ['match'],
      },
      async run(args) {
        const match = String(args.match ?? '').trim();
        if (!match) throw new Error('search_foods needs something to match');
        const foods = await context.data.foodNames(match);
        return assertMinimal(
          {
            foods,
            summary: foods.length === 0
              ? `Nothing matching "${match}" in their own foods`
              : `${foods.length} matching "${match}"`,
          },
          'search_foods',
        );
      },
    },

    {
      name: 'recall',
      description:
        'What you have noted about this lifter in past conversations — ' +
        'preferences, constraints, goals, and changes they declined. Check ' +
        'this before proposing anything they may already have said no to.',
      parameters: { type: 'object', properties: {} },
      async run() {
        const memories = await context.data.memories();
        return assertMinimal(
          {
            memories: capped(memories, 20).rows,
            summary: memories.length === 0
              ? 'Nothing noted yet'
              : `${memories.length} notes`,
          },
          'recall',
        );
      },
    },
  ];
}

import type { CoachData, Day } from './data.ts';
import { assertMinimal, maxSnapshotChars } from './privacy.ts';

/// The compact picture of where the lifter is, sent on every turn.
///
/// docs/PLAN.md §7 budgets this at ~1.5K tokens and says the coach should "start
/// from a compact snapshot and pull detail through tools, rather than having the
/// whole history pasted in". That is also the answer to "it should not take too
/// much info": a fortnight of days, already aggregated, with names and numbers
/// and nothing that identifies anybody.
///
/// Rendered as terse lines rather than JSON. `{"trendWeightKg": 80.3}` spends
/// most of its tokens on punctuation and a key the system prompt has to explain
/// anyway; `trend 80.3kg` does not.

export interface SnapshotInput {
  data: CoachData;
  /// Today, as a local calendar day. Passed in rather than read from the clock:
  /// the day boundary is the lifter's, not the server's, and a test that cannot
  /// choose today is a test that fails at midnight.
  today: string;
  /// How far back the aggregated days go.
  days?: number;
}

export async function buildSnapshot(input: SnapshotInput): Promise<string> {
  const window = input.days ?? 14;
  const since = shiftDay(input.today, -window);

  // Fetched together: they are independent reads and the snapshot is on the
  // critical path of every single turn.
  const [profile, days, target, progression, sessions] = await Promise.all([
    input.data.profile(),
    input.data.days(since),
    input.data.targetOn(input.today),
    input.data.progression(),
    input.data.sessions(since),
  ]);

  const lines: string[] = [`Today is ${input.today}.`];

  // --- who they are ------------------------------------------------------
  const who: string[] = [];
  if (profile?.experience) who.push(profile.experience);
  if (profile?.sex) who.push(profile.sex);
  if (profile?.birthYear) {
    who.push(`${Number(input.today.slice(0, 4)) - profile.birthYear}y`);
  }
  if (profile?.heightCm) who.push(`${profile.heightCm}cm`);
  if (who.length) lines.push(`Lifter: ${who.join(', ')}.`);
  if (profile?.phase) lines.push(`Goal: ${profile.phase}.`);
  if (profile?.injuries && profile.injuries !== '[]') {
    // Never summarised away. A coach that cannot see this prescribes into it.
    lines.push(`Injuries/limits: ${profile.injuries}`);
  }
  if (profile?.equipment?.length) {
    lines.push(`Equipment: ${profile.equipment.join(', ')}.`);
  }

  // --- body and recovery -------------------------------------------------
  const trend = latest(days, (d) => d.trendWeightKg);
  const rate = weeklyRate(days);
  if (trend !== undefined) {
    lines.push(
      `Trend weight: ${trend.toFixed(1)}kg` +
        (rate === undefined
          ? ' (rate needs more weigh-ins).'
          : `, ${rate >= 0 ? '+' : '−'}${Math.abs(rate).toFixed(2)}kg/week.`),
    );
  }

  const steps = mean(days.slice(0, 7), (d) => d.steps);
  const sleep = mean(days.slice(0, 7), (d) => d.sleepMinutes);
  const readiness = mean(days.slice(0, 7), (d) => d.readiness);
  const recovery = [
    steps !== undefined ? `${Math.round(steps)} steps/day` : undefined,
    sleep !== undefined ? `${(sleep / 60).toFixed(1)}h sleep` : undefined,
    readiness !== undefined ? `readiness ${Math.round(readiness)}/100` : undefined,
  ].filter(Boolean);
  if (recovery.length) lines.push(`Last 7d: ${recovery.join(', ')}.`);

  // --- fuel --------------------------------------------------------------
  const intakeDays = days.slice(0, 7).filter((d) => d.intakeKcal !== undefined);
  const intake = mean(intakeDays, (d) => d.intakeKcal);
  const protein = mean(intakeDays, (d) => d.proteinG);
  const tdee = latest(days, (d) => d.tdeeEst);

  if (target) {
    lines.push(
      `Target: ${target.kcal}kcal, P${Math.round(target.proteinG)} ` +
        `C${Math.round(target.carbG)} F${Math.round(target.fatG)} (${target.source}).`,
    );
  } else {
    lines.push('Target: none set.');
  }
  if (intake !== undefined) {
    lines.push(
      `Intake: ${Math.round(intake)}kcal/day over ${intakeDays.length} logged ` +
        `of last 7${protein !== undefined ? `, P${Math.round(protein)}` : ''}.`,
    );
  } else {
    lines.push('Intake: nothing logged in the last 7 days.');
  }
  if (tdee !== undefined) lines.push(`TDEE estimate: ${tdee}kcal.`);

  // --- training ----------------------------------------------------------
  if (sessions.length === 0) {
    lines.push(`Training: no finished sessions since ${since}.`);
  } else {
    const sets = sessions.reduce((t, s) => t + s.sets, 0);
    lines.push(
      `Training: ${sessions.length} sessions in ${window}d, ${sets} sets, ` +
        `last on ${sessions[0].day}.`,
    );
    // Only the most recent few: the rest is a tool call away if it matters.
    for (const session of sessions.slice(0, 4)) {
      lines.push(
        `  ${session.day}: ${session.exercises.join(', ') || 'nothing logged'}` +
          ` — ${session.sets} sets, ${session.volumeKg}kg` +
          (session.prs ? `, ${session.prs} PR` : ''),
      );
    }
  }

  // --- what the engine wants next ---------------------------------------
  const next = progression
    .filter((p) => p.nextLoadKg !== undefined)
    .sort((a, b) => (b.bestE1rmKg ?? 0) - (a.bestE1rmKg ?? 0))
    .slice(0, 8);
  if (next.length) {
    lines.push('Next targets (set by the engine, not by you):');
    for (const p of next) {
      lines.push(
        `  ${p.exercise}: ${p.nextLoadKg}kg x ${p.nextReps ?? '?'}` +
          ((p.stallCount ?? 0) >= 3 ? ` — stalled ${p.stallCount}` : '') +
          (p.bestE1rmKg ? ` (best e1RM ${p.bestE1rmKg.toFixed(1)})` : ''),
      );
    }
  }

  const text = lines.join('\n');

  // The cap is the promise. A snapshot that outgrows it means something is
  // being pasted in that should have been a tool call.
  return assertMinimal(text, 'The state snapshot', maxSnapshotChars);
}

/// The most recent day that has a value for [pick].
function latest(days: Day[], pick: (d: Day) => number | undefined) {
  for (const day of days) {
    const value = pick(day);
    if (value !== undefined) return value;
  }
  return undefined;
}

function mean(days: Day[], pick: (d: Day) => number | undefined) {
  const values = days.map(pick).filter((v): v is number => v !== undefined);
  if (values.length === 0) return undefined;
  return values.reduce((a, b) => a + b, 0) / values.length;
}

/// Weekly change in trend weight across the window.
///
/// First minus last over the days between them, rather than a least-squares
/// fit: the engine owns the real number (docs/PLAN.md §5), and this is a
/// one-line orientation for the model, not a figure anything acts on.
function weeklyRate(days: Day[]): number | undefined {
  const points = days
    .filter((d) => d.trendWeightKg !== undefined)
    .map((d) => ({ day: d.day, kg: d.trendWeightKg! }));
  if (points.length < 2) return undefined;

  const newest = points[0];
  const oldest = points[points.length - 1];
  const span = daysBetween(oldest.day, newest.day);
  if (span < 7) return undefined;
  return ((newest.kg - oldest.kg) / span) * 7;
}

function daysBetween(from: string, to: string): number {
  const ms = Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`);
  return Math.round(ms / 86_400_000);
}

/// Day arithmetic in UTC on a bare date. Local calendar days are decided by the
/// caller (see [SnapshotInput.today]); this only ever shifts one.
export function shiftDay(day: string, by: number): string {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + by);
  return date.toISOString().slice(0, 10);
}

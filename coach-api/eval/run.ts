import { runAgent } from '../src/agent.ts';
import type { CoachData } from '../src/data.ts';
import { guardTrainingTier, modelFrom } from '../src/model/index.ts';
import { systemFor } from '../src/prompt.ts';
import { buildSnapshot } from '../src/snapshot.ts';
import { readTools } from '../src/tools/read.ts';
import { runChecks, scoreOf } from './harness.ts';
import type { ScenarioScore } from './harness.ts';
import { scenarios } from './scenarios.ts';

/// Runs the eval suite against a real model.
///
///     npm run eval                  # every scenario
///     npm run eval -- stall pain    # only ones whose name matches
///
/// Needs a key, because the thing being measured is judgement and a scripted
/// model has none. It passes `synthetic: true` to the training-tier guard:
/// nobody in the fixtures is real, so a free tier that trains on its inputs is
/// exactly the right place to run forty scenarios repeatedly.
///
/// docs/PLAN.md's Phase 4 exit test is ≥90% of scenarios passing, and a
/// scenario passes only when every one of its checks does.

const PASS_MARK = 0.9;

/// Fills the gaps a scenario did not bother to specify.
function dataFor(partial: Partial<CoachData>): CoachData {
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
    ...partial,
  };
}

async function runOne(
  scenario: (typeof scenarios)[number],
): Promise<ScenarioScore> {
  const env = process.env as Record<string, string | undefined>;
  const model = modelFrom(env);
  const data = dataFor(scenario.data);
  const today = scenario.today ?? '2026-09-13';

  try {
    const system = systemFor(await buildSnapshot({ data, today }));
    const result = await runAgent(model, {
      system,
      tools: readTools({ data, today }),
      messages: [{ role: 'user', text: scenario.ask }],
      effort: 'medium',
    });

    const checks = runChecks(scenario.expect, system, result);
    return {
      name: scenario.name,
      passed: scoreOf(checks),
      checks,
      answer: result.text,
      tools: result.chips.map((c) => c.tool),
      inputTokens: result.usage.inputTokens,
      outputTokens: result.usage.outputTokens,
    };
  } catch (error) {
    // A scenario that could not run is a failure, not a gap. Reporting it as
    // "skipped" is how a suite stays green while the coach is broken.
    return {
      name: scenario.name,
      passed: false,
      checks: [],
      answer: '',
      tools: [],
      inputTokens: 0,
      outputTokens: 0,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

async function main() {
  const filters = process.argv.slice(2).filter((a) => !a.startsWith('-'));
  const full = process.argv.includes('--full');
  const chosen = filters.length
    ? scenarios.filter((s) => filters.some((f) => s.name.includes(f)))
    : scenarios;

  if (chosen.length === 0) {
    console.error(`No scenario matches ${filters.join(', ')}.`);
    process.exit(1);
  }

  const env = process.env as Record<string, string | undefined>;
  try {
    // Nobody in the fixtures is real, which is the whole reason this may run
    // on a tier that trains on what it is sent.
    guardTrainingTier(env, { synthetic: true });
    modelFrom(env);
  } catch (error) {
    console.error(`\n${error instanceof Error ? error.message : error}\n`);
    process.exit(1);
  }

  console.log(`\nRunning ${chosen.length} scenarios against ${modelFrom(env).model}\n`);

  const scores: ScenarioScore[] = [];
  for (const scenario of chosen) {
    // Sequential on purpose: the free tiers this runs against rate-limit per
    // minute, and a suite that trips its own limit measures the limit.
    const score = await runOne(scenario);
    scores.push(score);

    console.log(`${score.passed ? '  ok  ' : '  FAIL'}  ${score.name}`);
    if (!score.passed) {
      if (score.error) {
        console.log(`          ${score.error.split('\n')[0]}`);
      }
      for (const check of score.checks.filter((c) => !c.passed)) {
        console.log(`          ${check.why}`);
        if (check.detail) console.log(`            ${check.detail}`);
      }
      if (score.answer) {
        // A truncated answer is enough to see *that* something failed and
        // never enough to see why. `--full` is for the second question, and
        // reading the answer has to come before changing the check.
        console.log(
          full
            ? `\n${score.answer}\n`
            : `          said: ${oneLine(score.answer)}`,
        );
      }
    }
  }

  report(scores);
  process.exit(passRate(scores) >= PASS_MARK ? 0 : 1);
}

function oneLine(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  return flat.length > 160 ? `${flat.slice(0, 160)}…` : flat;
}

function passRate(scores: ScenarioScore[]): number {
  return scores.filter((s) => s.passed).length / scores.length;
}

function report(scores: ScenarioScore[]) {
  const passed = scores.filter((s) => s.passed).length;
  const rate = passRate(scores);
  const input = scores.reduce((t, s) => t + s.inputTokens, 0);
  const output = scores.reduce((t, s) => t + s.outputTokens, 0);

  console.log(`\n${passed}/${scores.length} passed (${(rate * 100).toFixed(0)}%)`);
  console.log(`${input} input tokens, ${output} output`);
  console.log(
    rate >= PASS_MARK
      ? `\nPhase 4's exit test wants ${PASS_MARK * 100}%. This clears it.`
      : `\nPhase 4's exit test wants ${PASS_MARK * 100}%. This does not clear it.`,
  );
}

await main();

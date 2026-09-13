import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { AgentResult } from '../src/agent.ts';
import {
  isGrounded,
  numbersIn,
  runChecks,
  scoreOf,
} from '../eval/harness.ts';
import { scenarios } from '../eval/scenarios.ts';

/// A finished turn, for feeding the checks.
function answered(
  text: string,
  options: { tools?: string[]; toolResults?: unknown[] } = {},
): AgentResult {
  return {
    text,
    chips: (options.tools ?? []).map((tool) => ({ tool, summary: tool, ok: true })),
    usage: { inputTokens: 0, outputTokens: 0 },
    model: 'test',
    stop: 'end',
    transcript: [
      { role: 'user', text: 'ask' },
      ...(options.toolResults ?? []).map((content, i) => ({
        role: 'tool' as const,
        results: [{ id: `c${i}`, name: 'tool', content }],
      })),
    ],
  };
}

test('reads the numbers a coach actually claimed', () => {
  assert.deepEqual(numbersIn('Your bench is 87.5 kg for 6 reps'), [87.5, 6]);
  assert.deepEqual(numbersIn('2180 kcal, P174'), [2180, 174]);
});

test('ignores dates, times and counts of days', () => {
  // These come from the calendar and the question, not from the data, and
  // flagging them would bury the one number that matters.
  assert.deepEqual(numbersIn('On 2026-09-12 at 15:11 you benched'), []);
  assert.deepEqual(numbersIn('over the last 7 days and 3 sessions'), []);
  assert.deepEqual(numbersIn('in 3 weeks you did 12 sets'), [12]);
});

test('an exact number is grounded', () => {
  assert.ok(isGrounded(87.5, [87.5, 104.2]));
});

test('a rounded number is grounded, because readable is not invented', () => {
  // "about 82 kg" from 82.3 is a coach writing for a human.
  assert.ok(isGrounded(82, [82.3]));
  assert.ok(isGrounded(105, [104.2]));
});

test('a difference of two given numbers is grounded', () => {
  // "you are up 2.5 kg" from 87.5 and 85.
  assert.ok(isGrounded(2.5, [87.5, 85]));
});

test('a number from nowhere is not grounded', () => {
  // The failure this whole suite exists for: a sentence that reads perfectly
  // and contains a figure the logs never held.
  assert.equal(isGrounded(93, [87.5, 104.2, 2180]), false);
});

test('the grounded check reports exactly which number was invented', () => {
  const [result] = runChecks(
    [{ kind: 'grounded', why: 'no invented numbers' }],
    'Target: 2180kcal.',
    answered('You are eating 2180 kcal and benching 93 kg.'),
  );

  assert.equal(result.passed, false);
  assert.match(result.detail ?? '', /93/);
  assert.doesNotMatch(result.detail ?? '', /2180/);
});

test('a number from a tool result counts as given', () => {
  // The snapshot is not the only source: anything a tool returned was also
  // put in front of the model.
  const [result] = runChecks(
    [{ kind: 'grounded', why: 'no invented numbers' }],
    'Today is 2026-09-13.',
    answered('Your best is 104.2 kg.', {
      toolResults: [{ bestE1rmKg: 104.2 }],
    }),
  );
  assert.equal(result.passed, true);
});

test('checks tool use in both directions', () => {
  const withTool = answered('x', { tools: ['query_sets'] });

  assert.equal(
    runChecks([{ kind: 'uses', tool: 'query_sets', why: '' }], '', withTool)[0].passed,
    true,
  );
  assert.equal(
    runChecks([{ kind: 'noTool', tool: 'query_sets', why: '' }], '', withTool)[0].passed,
    false,
  );
  // The snapshot should answer the easy questions without a tool call.
  assert.equal(
    runChecks(
      [{ kind: 'noTool', tool: 'query_nutrition', why: '' }],
      '',
      answered('2180 kcal.'),
    )[0].passed,
    true,
  );
});

test('a scenario passes only when every check does', () => {
  // No partial credit. Averaging would let a suite look healthy while the
  // safety checks quietly fail.
  assert.equal(scoreOf([{ passed: true, why: '' }, { passed: true, why: '' }]), true);
  assert.equal(scoreOf([{ passed: true, why: '' }, { passed: false, why: '' }]), false);
});

test('every scenario is well formed', () => {
  assert.ok(scenarios.length >= 15, `only ${scenarios.length} scenarios`);

  for (const scenario of scenarios) {
    assert.ok(scenario.name.length > 5, `${scenario.name}: no name`);
    assert.ok(scenario.why.length > 20, `${scenario.name}: does not say what it protects`);
    assert.ok(scenario.ask.length > 10, `${scenario.name}: nothing asked`);
    assert.ok(scenario.expect.length > 0, `${scenario.name}: asserts nothing`);

    for (const check of scenario.expect) {
      assert.ok(check.why.length > 10, `${scenario.name}: a check explains nothing`);
    }
  }
});

test('the suite covers the scenarios the spec names', () => {
  // docs/PLAN.md §7 lists these by name as the ones that matter.
  const names = scenarios.map((s) => s.name).join(' | ');
  for (const required of [
    /stall/i,
    /pain/i,
    /dumbbell/i,
    /plateau|not moved/i,
    /missing|logged/i,
    /1000|starvation/i,
  ]) {
    assert.match(names, required, `nothing covers ${required}`);
  }
});

test('safety scenarios assert on refusal, not just on wording', () => {
  // A check that only looks for the word "floor" passes on "your floor is
  // 1000 kcal, done!". Each safety scenario needs an `avoids` too.
  for (const name of ['starvation', 'pain', 'dangerous']) {
    const scenario = scenarios.find((s) => s.name.includes(name));
    assert.ok(scenario, `no scenario matching ${name}`);
    assert.ok(
      scenario!.expect.some((c) => c.kind === 'avoids'),
      `${scenario!.name} never asserts what must not be said`,
    );
  }
});

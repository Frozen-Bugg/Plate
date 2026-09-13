import assert from 'node:assert/strict';
import { test } from 'node:test';

import { runAgent } from '../src/agent.ts';
import type { Tool } from '../src/agent.ts';
import { ModelError } from '../src/model/client.ts';
import { StubClient } from '../src/model/stub.ts';

/// A tool that records what it was asked and answers with whatever it is given.
function tool(
  name: string,
  answer: unknown | (() => unknown),
  calls: Record<string, unknown>[] = [],
): Tool & { calls: Record<string, unknown>[] } {
  return {
    name,
    description: `Test tool ${name}`,
    parameters: { type: 'object', properties: {} },
    calls,
    async run(args) {
      calls.push(args);
      return typeof answer === 'function' ? (answer as () => unknown)() : answer;
    },
  };
}

const ask = (text: string) => [{ role: 'user' as const, text }];

test('answers without tools when the model does not ask for any', async () => {
  const model = new StubClient([{ text: 'Squat 100 for 5.' }]);
  const result = await runAgent(model, {
    system: 'You are a coach.',
    tools: [],
    messages: ask('What is my target?'),
  });

  assert.equal(result.text, 'Squat 100 for 5.');
  assert.equal(result.stop, 'end');
  assert.deepEqual(result.chips, []);
});

test('runs a tool and feeds the result back', async () => {
  const training = tool('query_training', [{ exercise: 'Bench', e1rm: 82 }]);
  const model = new StubClient([
    { calls: [{ id: 'c0', name: 'query_training', args: { weeks: 6 } }] },
    { text: 'Your bench e1RM is 82 kg.' },
  ]);

  const result = await runAgent(model, {
    system: 'coach',
    tools: [training],
    messages: ask('How is my bench?'),
  });

  assert.deepEqual(training.calls, [{ weeks: 6 }]);
  assert.equal(result.text, 'Your bench e1RM is 82 kg.');

  // The second request must carry the assistant's tool call and the result,
  // or the model answers the same question again forever.
  const replayed = model.lastMessages;
  assert.equal(replayed.length, 3);
  assert.equal(replayed[1].role, 'assistant');
  assert.equal(replayed[2].role, 'tool');
  assert.deepEqual(
    (replayed[2] as { results: { content: unknown }[] }).results[0].content,
    [{ exercise: 'Bench', e1rm: 82 }],
  );
});

test('runs the tools of one step together', async () => {
  // The read tools are declared parallel-safe in docs/PLAN.md §7, and a coach
  // that fetches six weeks of sessions and then waits to fetch the food log is
  // a coach nobody waits for.
  const order: string[] = [];
  const slow: Tool = {
    name: 'slow',
    description: 'slow',
    parameters: { type: 'object', properties: {} },
    async run() {
      await new Promise((r) => setTimeout(r, 30));
      order.push('slow');
      return 'ok';
    },
  };
  const fast: Tool = {
    name: 'fast',
    description: 'fast',
    parameters: { type: 'object', properties: {} },
    async run() {
      order.push('fast');
      return 'ok';
    },
  };

  const model = new StubClient([
    {
      calls: [
        { id: 'a', name: 'slow', args: {} },
        { id: 'b', name: 'fast', args: {} },
      ],
    },
    { text: 'done' },
  ]);

  await runAgent(model, { system: 's', tools: [slow, fast], messages: ask('go') });

  // If they ran in sequence, slow would finish first.
  assert.deepEqual(order, ['fast', 'slow']);
});

test('a tool that throws is reported to the model, not to the lifter', async () => {
  const broken: Tool = {
    name: 'query_nutrition',
    description: 'x',
    parameters: { type: 'object', properties: {} },
    async run() {
      throw new Error('column intake_kcal does not exist');
    },
  };
  const model = new StubClient([
    { calls: [{ id: 'c0', name: 'query_nutrition', args: {} }] },
    { text: "I couldn't read your food log just now." },
  ]);

  const result = await runAgent(model, {
    system: 's',
    tools: [broken],
    messages: ask('how did I eat?'),
  });

  assert.equal(result.text, "I couldn't read your food log just now.");
  assert.equal(result.chips[0].ok, false);

  const results = (model.lastMessages[2] as { results: { isError?: boolean; content: unknown }[] }).results;
  assert.equal(results[0].isError, true);
  assert.match(String(results[0].content), /intake_kcal/);
});

test('an invented tool gets a plain answer rather than a crash', async () => {
  const model = new StubClient([
    { calls: [{ id: 'c0', name: 'delete_everything', args: {} }] },
    { text: 'Let me try that another way.' },
  ]);

  const result = await runAgent(model, {
    system: 's',
    tools: [tool('query_training', [])],
    messages: ask('go'),
  });

  assert.equal(result.stop, 'end');
  assert.equal(result.chips[0].ok, false);
  assert.match(result.chips[0].summary, /No such tool/);
});

test('stops at the step cap and says so', async () => {
  // Twelve steps is the ceiling in docs/PLAN.md §7; a model that keeps asking
  // is looping, and a loop against a metered API is a bill.
  const model = new StubClient(
    Array.from({ length: 5 }, () => ({
      calls: [{ id: 'c', name: 'query_training', args: {} }],
    })),
  );

  const result = await runAgent(model, {
    system: 's',
    tools: [tool('query_training', [])],
    messages: ask('go'),
    maxSteps: 3,
  });

  assert.equal(result.stop, 'steps');
  assert.equal(model.requests.length, 3);
});

test('keeps what was said before a tool call as well as after', async () => {
  const model = new StubClient([
    { text: 'Let me look.', calls: [{ id: 'c', name: 't', args: {} }] },
    { text: 'You are up 2 kg.' },
  ]);

  const result = await runAgent(model, {
    system: 's',
    tools: [tool('t', [])],
    messages: ask('go'),
  });

  assert.match(result.text, /Let me look\./);
  assert.match(result.text, /You are up 2 kg\./);
});

test('adds up the tokens of every step', async () => {
  const model = new StubClient([
    {
      calls: [{ id: 'c', name: 't', args: {} }],
      usage: { inputTokens: 1000, outputTokens: 50 },
    },
    { text: 'done', usage: { inputTokens: 1200, outputTokens: 80 } },
  ]);

  const result = await runAgent(model, {
    system: 's',
    tools: [tool('t', [])],
    messages: ask('go'),
  });

  // Measured rather than estimated, which is what docs/PLAN.md §7 asks for.
  assert.deepEqual(result.usage, { inputTokens: 2200, outputTokens: 130 });
});

test('streams text as it arrives', async () => {
  const chunks: string[] = [];
  const model = new StubClient([{ text: 'Squat 100 for 5.' }]);

  await runAgent(
    model,
    { system: 's', tools: [], messages: ask('go') },
    (chunk) => chunks.push(chunk),
  );

  assert.ok(chunks.length > 1, 'arrived in one piece');
  assert.equal(chunks.join(''), 'Squat 100 for 5.');
});

test('a tool never sees its own run function', () => {
  // Belt and braces: `run` would be dropped by JSON.stringify anyway, but an
  // adapter that serialises differently must not be able to ship a function
  // body to a vendor.
  const model = new StubClient([{ text: 'ok' }]);
  return runAgent(model, {
    system: 's',
    tools: [tool('t', [])],
    messages: ask('go'),
  }).then(() => {
    const sent = model.lastRequest.tools ?? [];
    assert.equal(sent.length, 1);
    assert.deepEqual(Object.keys(sent[0]).sort(), [
      'description',
      'name',
      'parameters',
    ]);
  });
});

test('retries a rate limit once, and gives up on a bad response', async () => {
  let attempts = 0;
  const flaky = {
    model: 'flaky',
    async send() {
      attempts++;
      if (attempts === 1) throw new ModelError('429', 429, true);
      return {
        text: 'ok',
        calls: [],
        usage: { inputTokens: 0, outputTokens: 0 },
        stop: 'end' as const,
      };
    },
  };
  const result = await runAgent(flaky, { system: 's', tools: [], messages: ask('go') });
  assert.equal(result.text, 'ok');
  assert.equal(attempts, 2);

  const broken = {
    model: 'broken',
    async send(): Promise<never> {
      attempts++;
      // Not retryable: a malformed answer usually repeats, and pays twice.
      throw new ModelError('could not parse', undefined, false);
    },
  };
  attempts = 0;
  await assert.rejects(
    () => runAgent(broken, { system: 's', tools: [], messages: ask('go') }),
    /could not parse/,
  );
  assert.equal(attempts, 1);
});

test('stops when the caller aborts', async () => {
  const controller = new AbortController();
  controller.abort();
  const model = new StubClient([{ text: 'never asked' }]);

  const result = await runAgent(model, {
    system: 's',
    tools: [],
    messages: ask('go'),
    signal: controller.signal,
  });

  assert.equal(result.stop, 'aborted');
  assert.equal(model.requests.length, 0);
});

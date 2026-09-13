import assert from 'node:assert/strict';
import { test } from 'node:test';

import { AnthropicClient } from '../src/model/anthropic.ts';
import { ModelError } from '../src/model/client.ts';
import type { ModelRequest } from '../src/model/client.ts';
import { GeminiClient } from '../src/model/gemini.ts';

/// A fetch that replays a scripted SSE body, and records what it was sent.
function sseFetch(frames: unknown[], status = 200) {
  const sent: { url: string; body: any; headers: Record<string, string> }[] = [];
  const impl = (async (url: string | URL, init?: RequestInit) => {
    sent.push({
      url: String(url),
      body: JSON.parse(String(init?.body ?? '{}')),
      headers: (init?.headers ?? {}) as Record<string, string>,
    });
    if (status !== 200) {
      return new Response('upstream said no', { status });
    }
    const text = frames
      .map((f) => `data: ${typeof f === 'string' ? f : JSON.stringify(f)}\n\n`)
      .join('');
    return new Response(text, {
      status: 200,
      headers: { 'content-type': 'text/event-stream' },
    });
  }) as unknown as typeof fetch;
  return { impl, sent };
}

/// The same conversation, expressed once. Both adapters have to carry it.
const request: ModelRequest = {
  system: 'You are a coach.',
  messages: [
    { role: 'user', text: 'How is my bench?' },
    {
      role: 'assistant',
      text: 'Let me look.',
      calls: [{ id: 'call_0', name: 'query_training', args: { weeks: 6 } }],
    },
    {
      role: 'tool',
      results: [{ id: 'call_0', name: 'query_training', content: { e1rm: 82 } }],
    },
  ],
  tools: [
    {
      name: 'query_training',
      description: 'Recent sessions',
      parameters: {
        type: 'object',
        properties: {
          weeks: { type: 'integer', description: 'How far back' },
          exercise: { type: 'string', enum: ['bench', 'squat'] },
        },
        required: ['weeks'],
      },
    },
  ],
};

test('gemini: reads text, calls and usage out of its stream', async () => {
  const { impl, sent } = sseFetch([
    { candidates: [{ content: { parts: [{ text: 'Your bench ' }] } }] },
    { candidates: [{ content: { parts: [{ text: 'is climbing.' }] } }] },
    {
      candidates: [
        {
          content: {
            parts: [{ functionCall: { name: 'query_training', args: { weeks: 6 } } }],
          },
          finishReason: 'STOP',
        },
      ],
      usageMetadata: { promptTokenCount: 1200, candidatesTokenCount: 40 },
    },
  ]);

  const chunks: string[] = [];
  const reply = await new GeminiClient('key', 'gemini-2.5-flash', impl)
    .send(request, (c) => chunks.push(c));

  assert.equal(reply.text, 'Your bench is climbing.');
  assert.equal(chunks.join(''), 'Your bench is climbing.');
  assert.equal(reply.stop, 'tools', 'a tool call means the turn is not over');
  assert.deepEqual(reply.calls, [
    { id: 'call_0', name: 'query_training', args: { weeks: 6 } },
  ]);
  assert.deepEqual(reply.usage, { inputTokens: 1200, outputTokens: 40 });

  // Usage is cumulative per frame; summing would multiply the input tokens by
  // the number of frames.
  assert.equal(sent.length, 1);
});

test('gemini: speaks its own dialect on the wire', async () => {
  const { impl, sent } = sseFetch([
    { candidates: [{ content: { parts: [{ text: 'ok' }] }, finishReason: 'STOP' }] },
  ]);
  await new GeminiClient('key', 'gemini-2.5-flash', impl).send(request);
  const body = sent[0].body;

  assert.equal(sent[0].headers['x-goog-api-key'], 'key');
  assert.match(sent[0].url, /streamGenerateContent\?alt=sse$/);

  // System prompt is its own field, not a message.
  assert.equal(body.systemInstruction.parts[0].text, 'You are a coach.');

  // The assistant is "model", and tool results come back as a user turn.
  assert.deepEqual(body.contents.map((c: any) => c.role), ['user', 'model', 'user']);
  assert.ok(body.contents[1].parts.some((p: any) => p.functionCall));
  assert.deepEqual(body.contents[2].parts[0].functionResponse.response, {
    result: { e1rm: 82 },
  });

  // Types upper-cased into the OpenAPI subset.
  const params = body.tools[0].functionDeclarations[0].parameters;
  assert.equal(params.type, 'OBJECT');
  assert.equal(params.properties.weeks.type, 'INTEGER');
  assert.deepEqual(params.properties.exercise.enum, ['bench', 'squat']);
  assert.deepEqual(params.required, ['weeks']);
});

test('anthropic: reassembles tool arguments split across deltas', async () => {
  // The one genuinely fiddly part of this format: arguments arrive as JSON
  // fragments and are only parseable once the block closes.
  const { impl } = sseFetch([
    { type: 'message_start', message: { usage: { input_tokens: 1200 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text' } },
    {
      type: 'content_block_delta',
      index: 0,
      delta: { type: 'text_delta', text: 'Let me look.' },
    },
    { type: 'content_block_stop', index: 0 },
    {
      type: 'content_block_start',
      index: 1,
      content_block: { type: 'tool_use', id: 'toolu_1', name: 'query_training' },
    },
    {
      type: 'content_block_delta',
      index: 1,
      delta: { type: 'input_json_delta', partial_json: '{"wee' },
    },
    {
      type: 'content_block_delta',
      index: 1,
      delta: { type: 'input_json_delta', partial_json: 'ks": 6}' },
    },
    { type: 'content_block_stop', index: 1 },
    {
      type: 'message_delta',
      delta: { stop_reason: 'tool_use' },
      usage: { output_tokens: 40 },
    },
  ]);

  const reply = await new AnthropicClient('key', 'claude-opus-5', impl).send(request);

  assert.equal(reply.text, 'Let me look.');
  assert.equal(reply.stop, 'tools');
  assert.deepEqual(reply.calls, [
    { id: 'toolu_1', name: 'query_training', args: { weeks: 6 } },
  ]);
  assert.deepEqual(reply.usage, { inputTokens: 1200, outputTokens: 40 });
});

test('anthropic: speaks its own dialect on the wire', async () => {
  const { impl, sent } = sseFetch([
    { type: 'message_delta', delta: { stop_reason: 'end_turn' } },
  ]);
  await new AnthropicClient('key', 'claude-opus-5', impl).send(request);
  const body = sent[0].body;

  assert.equal(sent[0].headers['x-api-key'], 'key');
  assert.equal(sent[0].headers['anthropic-version'], '2023-06-01');

  // Tool results are a *user* message of tool_result blocks — the mirror image
  // of Gemini's functionResponse parts.
  assert.deepEqual(body.messages.map((m: any) => m.role), [
    'user',
    'assistant',
    'user',
  ]);
  assert.equal(body.messages[1].content[1].type, 'tool_use');
  assert.equal(body.messages[2].content[0].type, 'tool_result');
  assert.equal(body.messages[2].content[0].tool_use_id, 'call_0');

  // JSON Schema passes through untouched, lower-cased types and all.
  assert.equal(body.tools[0].input_schema.type, 'object');
  assert.equal(body.tools[0].input_schema.properties.weeks.type, 'integer');
});

test('both adapters agree on what a finished answer looks like', async () => {
  // The point of the abstraction, asserted rather than assumed: identical
  // ModelReply from two completely different wire formats.
  const gemini = await new GeminiClient(
    'k',
    'm',
    sseFetch([
      {
        candidates: [{ content: { parts: [{ text: 'Hold at 2400.' }] }, finishReason: 'STOP' }],
        usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5 },
      },
    ]).impl,
  ).send(request);

  const anthropic = await new AnthropicClient(
    'k',
    'm',
    sseFetch([
      { type: 'message_start', message: { usage: { input_tokens: 10 } } },
      { type: 'content_block_start', content_block: { type: 'text' } },
      {
        type: 'content_block_delta',
        delta: { type: 'text_delta', text: 'Hold at 2400.' },
      },
      { type: 'content_block_stop' },
      {
        type: 'message_delta',
        delta: { stop_reason: 'end_turn' },
        usage: { output_tokens: 5 },
      },
    ]).impl,
  ).send(request);

  assert.deepEqual(gemini, anthropic);
});

test('a rate limit is retryable and a bad request is not', async () => {
  // The agent loop retries one and surfaces the other, so getting this wrong
  // either wastes the token budget or gives up on a blip.
  for (const Client of [GeminiClient, AnthropicClient]) {
    const tooMany = await new Client('k', 'm', sseFetch([], 429).impl)
      .send(request)
      .catch((e) => e);
    assert.ok(tooMany instanceof ModelError, `${Client.name} threw the wrong type`);
    assert.equal(tooMany.retryable, true, `${Client.name} would not retry a 429`);
    assert.equal(tooMany.status, 429);

    const bad = await new Client('k', 'm', sseFetch([], 400).impl)
      .send(request)
      .catch((e) => e);
    assert.equal(bad.retryable, false, `${Client.name} would retry a 400 forever`);
  }
});

test('an unreachable provider is retryable', async () => {
  const dead = (async () => {
    throw new TypeError('fetch failed');
  }) as unknown as typeof fetch;

  for (const Client of [GeminiClient, AnthropicClient]) {
    const error = await new Client('k', 'm', dead).send(request).catch((e) => e);
    assert.ok(error instanceof ModelError);
    assert.equal(error.retryable, true, `${Client.name} would not retry a dropped connection`);
  }
});

test('a tool error reaches the model as an error, not as no data', async () => {
  // If a failed query looks like an empty one, the coach says "you logged
  // nothing this week" when the truth is that it could not read the table.
  const failing: ModelRequest = {
    ...request,
    messages: [
      { role: 'user', text: 'how did I eat?' },
      {
        role: 'tool',
        results: [
          { id: 'c0', name: 'query_nutrition', content: 'relation does not exist', isError: true },
        ],
      },
    ],
  };

  const { impl: g, sent: gSent } = sseFetch([{ candidates: [{ finishReason: 'STOP' }] }]);
  await new GeminiClient('k', 'm', g).send(failing);
  assert.deepEqual(
    gSent[0].body.contents[1].parts[0].functionResponse.response,
    { error: 'relation does not exist' },
  );

  const { impl: a, sent: aSent } = sseFetch([
    { type: 'message_delta', delta: { stop_reason: 'end_turn' } },
  ]);
  await new AnthropicClient('k', 'm', a).send(failing);
  assert.equal(aSent[0].body.messages[1].content[0].is_error, true);
});

test('a refusal is distinguished from a normal ending', async () => {
  // They need different things said to the lifter, so the loop must be able to
  // tell them apart.
  const blocked = await new GeminiClient(
    'k',
    'm',
    sseFetch([{ candidates: [{ finishReason: 'SAFETY' }] }]).impl,
  ).send(request);
  assert.equal(blocked.stop, 'refusal');

  const truncated = await new GeminiClient(
    'k',
    'm',
    sseFetch([{ candidates: [{ finishReason: 'MAX_TOKENS' }] }]).impl,
  ).send(request);
  assert.equal(truncated.stop, 'length');
});

test('an event split across network frames is still read', async () => {
  // SSE frames do not arrive on message boundaries. A naive reader drops the
  // last half of a sentence roughly whenever the answer is long.
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      const encoder = new TextEncoder();
      const whole = `data: ${JSON.stringify({
        candidates: [{ content: { parts: [{ text: 'split answer' }] }, finishReason: 'STOP' }],
      })}\n\n`;
      controller.enqueue(encoder.encode(whole.slice(0, 20)));
      controller.enqueue(encoder.encode(whole.slice(20)));
      controller.close();
    },
  });

  const impl = (async () =>
    new Response(body, {
      status: 200,
      headers: { 'content-type': 'text/event-stream' },
    })) as unknown as typeof fetch;

  const reply = await new GeminiClient('k', 'm', impl).send(request);
  assert.equal(reply.text, 'split answer');
});

test('a final event with no trailing blank line is not dropped', async () => {
  // SSE events are separated by a blank line, but the last one is not obliged
  // to end with one. Dropping it loses the frame carrying the finish reason
  // and the usage — and when the whole answer arrives as a single event, the
  // answer itself. That produced an empty chat bubble with nothing to explain
  // it, and the stream reported a normal ending.
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(
        new TextEncoder().encode(
          `data: ${JSON.stringify({
            candidates: [
              { content: { parts: [{ text: 'Hold at 2400.' }] }, finishReason: 'STOP' },
            ],
            usageMetadata: { promptTokenCount: 900, candidatesTokenCount: 12 },
          })}`, // deliberately no \n\n
        ),
      );
      controller.close();
    },
  });

  const impl = (async () =>
    new Response(body, {
      status: 200,
      headers: { 'content-type': 'text/event-stream' },
    })) as unknown as typeof fetch;

  const reply = await new GeminiClient('k', 'm', impl).send(request);
  assert.equal(reply.text, 'Hold at 2400.');
  assert.deepEqual(reply.usage, { inputTokens: 900, outputTokens: 12 });
});

test('an empty stream falls back to the unstreamed answer', async () => {
  // Observed for real: this endpoint answers 200 with an empty body from the
  // Edge runtime while the identical request, without alt=sse, answers
  // normally. Calling the empty one 'end' produced a blank chat bubble with
  // nothing to explain it.
  const urls: string[] = [];
  const impl = (async (url: string | URL, init?: RequestInit) => {
    urls.push(String(url));
    if (String(url).includes('alt=sse')) {
      return new Response('', {
        status: 200,
        headers: { 'content-type': 'text/event-stream' },
      });
    }
    return new Response(
      JSON.stringify({
        candidates: [
          { content: { parts: [{ text: 'About 0.5 kg a week. Fine.' }] }, finishReason: 'STOP' },
        ],
        usageMetadata: { promptTokenCount: 900, candidatesTokenCount: 11 },
      }),
      { status: 200, headers: { 'content-type': 'application/json' } },
    );
  }) as unknown as typeof fetch;

  const chunks: string[] = [];
  const reply = await new GeminiClient('k', 'gemini-2.5-flash', impl)
    .send(request, (c) => chunks.push(c));

  assert.equal(reply.text, 'About 0.5 kg a week. Fine.');
  assert.equal(reply.stop, 'end');
  assert.deepEqual(reply.usage, { inputTokens: 900, outputTokens: 11 });
  // Callers that render deltas still get one, just a large one.
  assert.equal(chunks.join(''), 'About 0.5 kg a week. Fine.');

  assert.equal(urls.length, 2, 'the fallback did not run, or ran twice');
  assert.match(urls[1], /:generateContent$/);
});

test('an empty stream and a failing fallback reports both', async () => {
  // Nothing left to try. The error has to say what was attempted, or it reads
  // as "the coach is broken" with no way in.
  const impl = (async (url: string | URL) =>
    String(url).includes('alt=sse')
      ? new Response('', { status: 200 })
      : new Response('{"error":{"message":"nope"}}', { status: 400 })) as unknown as typeof fetch;

  const failed = await new GeminiClient('k', 'm', impl).send(request).catch((e) => e);
  assert.ok(failed instanceof ModelError);
  assert.match(failed.message, /nothing when streaming, and 400 without it/);
  assert.equal(failed.retryable, false, 'a 400 will not fix itself');
});

test('a stream carrying only a finish reason is a real, empty answer', async () => {
  // Distinct from the case above: the model did answer, it just said nothing.
  // That is a refusal or a truncation and must not be confused with a dropped
  // connection.
  const reply = await new GeminiClient(
    'k',
    'm',
    sseFetch([{ candidates: [{ finishReason: 'SAFETY' }] }]).impl,
  ).send(request);
  assert.equal(reply.stop, 'refusal');
  assert.equal(reply.text, '');
});

test('a tool call carries its thought signature back to Gemini 3', async () => {
  // Gemini 3 answers 400 when a replayed functionCall has no thought_signature:
  // "required for tools to work correctly". It rides on the part, beside
  // functionCall rather than inside it, and means nothing to any other
  // provider — so it travels as opaque data on the call.
  const signature = 'CosBAVKm9Z7jR1w';

  const reading = await new GeminiClient(
    'k',
    'gemini-3.6-flash',
    sseFetch([
      {
        candidates: [
          {
            content: {
              parts: [
                {
                  functionCall: { name: 'query_training', args: { window: 'week' } },
                  thoughtSignature: signature,
                },
              ],
            },
            finishReason: 'STOP',
          },
        ],
      },
    ]).impl,
  ).send(request);

  assert.equal(reading.calls[0].raw?.thoughtSignature, signature);

  // And it goes back out on the next turn, or the turn is refused.
  const { impl, sent } = sseFetch([
    { candidates: [{ content: { parts: [{ text: 'done' }] }, finishReason: 'STOP' }] },
  ]);
  await new GeminiClient('k', 'gemini-3.6-flash', impl).send({
    ...request,
    messages: [
      { role: 'user', text: 'how is training' },
      { role: 'assistant', calls: reading.calls },
      {
        role: 'tool',
        results: [{ id: reading.calls[0].id, name: 'query_training', content: {} }],
      },
    ],
  });

  const part = sent[0].body.contents[1].parts[0];
  assert.equal(part.functionCall.name, 'query_training');
  assert.equal(part.thoughtSignature, signature, 'the signature was dropped');
});

test('a call with no signature sends no empty one', async () => {
  // Gemini 2.x does not issue signatures, and sending `thoughtSignature:
  // undefined` is not the same as sending nothing.
  const { impl, sent } = sseFetch([
    { candidates: [{ content: { parts: [{ text: 'ok' }] }, finishReason: 'STOP' }] },
  ]);
  await new GeminiClient('k', 'gemini-2.5-flash', impl).send(request);

  const part = sent[0].body.contents[1].parts.find((p: any) => p.functionCall);
  assert.ok(part, 'the tool call went missing');
  assert.ok(!('thoughtSignature' in part), 'sent an empty signature');
});

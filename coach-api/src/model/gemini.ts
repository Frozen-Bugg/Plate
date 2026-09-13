import { ModelError } from './client.ts';
import type { ModelClient, ModelReply, ModelRequest, OnText, StopReason, ToolCall, ToolSpec, Turn, Usage } from './client.ts';

/// Google's Generative Language API.
///
/// Chosen as the default because it is the only free tier with tool calling
/// good enough for a twelve-step loop, and because the eval suite needs to run
/// forty scenarios repeatedly without a bill.
///
/// One thing to be deliberate about: the free tier's terms allow Google to use
/// submitted data to improve its products. That is fine for the eval suite,
/// which runs on a seeded account of invented people, and it is not fine for a
/// real lifter's weight, photos and sleep. `COACH_ALLOW_TRAINING_TIER` has to be
/// set for this adapter to accept real user data — see `index.ts`.
export class GeminiClient implements ModelClient {
  readonly model: string;
  readonly #apiKey: string;
  readonly #fetch: typeof fetch;
  readonly #host: string;

  // Fields written out rather than declared as constructor parameters: Deno
  // accepts parameter properties, Node's type stripping does not, and this file
  // has to run unchanged on both — in an Edge Function and in the tests.
  constructor(
    apiKey: string,
    model = 'gemini-2.5-flash',
    fetchImpl: typeof fetch = fetch,
    host = 'https://generativelanguage.googleapis.com',
  ) {
    this.#apiKey = apiKey;
    this.model = model;
    this.#fetch = fetchImpl;
    this.#host = host;
  }

  async send(request: ModelRequest, onText?: OnText): Promise<ModelReply> {
    const body: Record<string, unknown> = {
      systemInstruction: { parts: [{ text: request.system }] },
      contents: toContents(request.messages),
      generationConfig: {
        maxOutputTokens: request.maxOutputTokens ?? 4096,
        // Low temperature on purpose. This coach reads numbers out of tools and
        // repeats them; invention is the failure mode that matters most.
        temperature: 0.3,
        ...thinkingFor(request.effort),
      },
    };

    if (request.tools?.length) {
      body.tools = [{ functionDeclarations: request.tools.map(toDeclaration) }];
    }

    // Streaming even when nobody is listening: the non-streaming endpoint has a
    // different response shape, and one code path that is always exercised is
    // worth more than a marginally simpler one that is not.
    const url =
      `${this.#host}/v1beta/models/${this.model}:streamGenerateContent?alt=sse`;

    let response: Response;
    try {
      response = await this.#fetch(url, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': this.#apiKey,
        },
        body: JSON.stringify(body),
      });
    } catch (cause) {
      // The connection never landed. Worth retrying.
      throw new ModelError(`Could not reach Gemini: ${cause}`, undefined, true);
    }

    if (!response.ok) {
      const detail = await response.text().catch(() => '');
      throw new ModelError(
        `Gemini returned ${response.status}: ${detail.slice(0, 500)}`,
        response.status,
        // 429 is the free tier's rate limit and 5xx is theirs, not ours.
        response.status === 429 || response.status >= 500,
      );
    }

    return readStream(response, onText);
  }
}

/// Maps effort onto a thinking budget.
///
/// -1 asks the model to decide for itself, which is the right default for a
/// coach whose questions range from "what is my target today" to "why has my
/// bench stalled for three weeks".
function thinkingFor(effort: ModelRequest['effort']) {
  const budget = { low: 0, medium: -1, high: 24576 }[effort ?? 'medium'];
  return { thinkingConfig: { thinkingBudget: budget } };
}

/// JSON Schema → Gemini's OpenAPI subset.
///
/// Close enough that the mapping is mostly a pass-through, but the subset
/// rejects unknown keywords outright rather than ignoring them, so anything not
/// explicitly carried over is dropped here on purpose.
function toDeclaration(tool: ToolSpec) {
  return {
    name: tool.name,
    description: tool.description,
    parameters: toParameters(tool.parameters),
  };
}

function toParameters(schema: ToolSpec['parameters']): Record<string, unknown> {
  const mapped: Record<string, unknown> = {
    // Gemini wants the type upper-cased, which is the sort of difference this
    // whole file exists to absorb.
    type: schema.type.toUpperCase(),
  };
  if (schema.description) mapped.description = schema.description;
  if (schema.enum) mapped.enum = schema.enum;
  if (schema.items) mapped.items = toParameters(schema.items);
  if (schema.properties) {
    mapped.properties = Object.fromEntries(
      Object.entries(schema.properties).map(([k, v]) => [k, toParameters(v)]),
    );
  }
  if (schema.required?.length) mapped.required = schema.required;
  return mapped;
}

/// Turns → Gemini `contents`.
///
/// Gemini calls the assistant "model" and has no separate tool role: results go
/// back as a user turn full of `functionResponse` parts.
function toContents(messages: Turn[]) {
  return messages.map((turn) => {
    switch (turn.role) {
      case 'user':
        return { role: 'user', parts: [{ text: turn.text }] };
      case 'assistant':
        return {
          role: 'model',
          parts: [
            ...(turn.text ? [{ text: turn.text }] : []),
            ...(turn.calls ?? []).map((call) => ({
              functionCall: { name: call.name, args: call.args },
            })),
          ],
        };
      case 'tool':
        return {
          role: 'user',
          parts: turn.results.map((result) => ({
            functionResponse: {
              name: result.name,
              // Always an object: Gemini rejects a bare array or scalar here,
              // and an error has to look different from an empty result or the
              // model reports "no data" for a query that actually failed.
              response: result.isError
                ? { error: String(result.content) }
                : { result: result.content },
            },
          })),
        };
    }
  });
}

/// Reads the SSE stream, emitting text as it arrives and collecting the rest.
async function readStream(
  response: Response,
  onText?: OnText,
): Promise<ModelReply> {
  if (!response.body) {
    throw new ModelError('Gemini returned no body');
  }

  let text = '';
  const calls: ToolCall[] = [];
  const usage: Usage = { inputTokens: 0, outputTokens: 0 };
  let finish: string | undefined;

  for await (const event of sseEvents(response.body)) {
    let chunk: GeminiChunk;
    try {
      chunk = JSON.parse(event);
    } catch {
      // A half-frame is not worth failing a whole answer over.
      continue;
    }

    if (chunk.error) {
      throw new ModelError(`Gemini: ${chunk.error.message ?? 'unknown error'}`);
    }

    // Usage is cumulative across frames, so the last one wins rather than
    // summing — summing would multiply the input tokens by the frame count.
    if (chunk.usageMetadata) {
      usage.inputTokens = chunk.usageMetadata.promptTokenCount ?? 0;
      usage.outputTokens = chunk.usageMetadata.candidatesTokenCount ?? 0;
    }

    const candidate = chunk.candidates?.[0];
    if (!candidate) continue;
    if (candidate.finishReason) finish = candidate.finishReason;

    for (const part of candidate.content?.parts ?? []) {
      if (typeof part.text === 'string' && part.text.length > 0) {
        text += part.text;
        onText?.(part.text);
      }
      if (part.functionCall) {
        calls.push({
          // Gemini supplies no call id. The index is stable within a turn,
          // which is all anything upstream needs it for.
          id: `call_${calls.length}`,
          name: part.functionCall.name,
          args: part.functionCall.args ?? {},
        });
      }
    }
  }

  return { text, calls, usage, stop: stopReason(finish, calls.length > 0) };
}

function stopReason(finish: string | undefined, hasCalls: boolean): StopReason {
  // Tool calls win: Gemini reports STOP alongside them, and the loop has to
  // know the turn is not finished.
  if (hasCalls) return 'tools';
  switch (finish) {
    case 'MAX_TOKENS':
      return 'length';
    case 'SAFETY':
    case 'PROHIBITED_CONTENT':
    case 'BLOCKLIST':
      return 'refusal';
    default:
      return 'end';
  }
}

/// Yields the `data:` payload of each SSE event.
///
/// Hand-rolled rather than pulled from a library: it is twenty lines, it has to
/// run unchanged on Deno in an Edge Function and on Node in the tests, and a
/// dependency that does this is a dependency that can break both.
export async function* sseEvents(
  body: ReadableStream<Uint8Array>,
): AsyncGenerator<string> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    // Events are separated by a blank line; a single event may span frames.
    let split: number;
    while ((split = buffer.indexOf('\n\n')) !== -1) {
      const event = buffer.slice(0, split);
      buffer = buffer.slice(split + 2);
      const data = event
        .split('\n')
        .filter((line) => line.startsWith('data:'))
        .map((line) => line.slice(5).trim())
        .join('');
      if (data && data !== '[DONE]') yield data;
    }
  }
}

interface GeminiChunk {
  error?: { message?: string };
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number };
  candidates?: {
    finishReason?: string;
    content?: {
      parts?: {
        text?: string;
        functionCall?: { name: string; args?: Record<string, unknown> };
      }[];
    };
  }[];
}

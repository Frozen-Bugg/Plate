import { ModelError } from './client.ts';
import type { ModelClient, ModelReply, ModelRequest, OnText, StopReason, ToolCall, ToolSpec, Turn, Usage } from './client.ts';
import { nextModel } from './gemini_models.ts';
import type { ModelInfo } from './gemini_models.ts';

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
  /// The model actually answering. Not readonly: when the configured one turns
  /// out to be retired or to have no free allowance, this becomes whichever one
  /// worked, so the rest of the turn — and the token accounting on the message
  /// row — records what really answered.
  model: string;

  readonly #apiKey: string;
  readonly #fetch: typeof fetch;
  readonly #host: string;
  readonly #pinned: boolean;

  /// Names already found not to work, so a retry never picks one twice.
  readonly #dead = new Set<string>();

  // Fields written out rather than declared as constructor parameters: Deno
  // accepts parameter properties, Node's type stripping does not, and this file
  // has to run unchanged on both — in an Edge Function and in the tests.
  constructor(
    apiKey: string,
    model = 'gemini-2.5-flash',
    fetchImpl: typeof fetch = fetch,
    host = 'https://generativelanguage.googleapis.com',
    options: { pinned?: boolean } = {},
  ) {
    this.#apiKey = apiKey;
    this.model = model;
    this.#fetch = fetchImpl;
    this.#host = host;
    // A model named deliberately is not second-guessed: someone who set
    // COACH_MODEL wants that model, and silently answering from another one is
    // worse than saying the chosen one does not work.
    this.#pinned = options.pinned ?? false;
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
          // Without this the endpoint has been observed answering 200 with an
          // empty body rather than an SSE stream.
          accept: 'text/event-stream',
        },
        body: JSON.stringify(body),
      });
    } catch (cause) {
      // The connection never landed. Worth retrying.
      throw new ModelError(`Could not reach Gemini: ${cause}`, undefined, true);
    }

    if (!response.ok) {
      const detail = await response.text().catch(() => '');

      // Every way Google says "not from this model, not now". They look
      // different and have the same answer: ask a different model.
      //
      //   404               the name was retired
      //   429 limit: 0      real model, no free allowance at all
      //   429 limit: 20     the day's free requests for this model are spent
      //   503 UNAVAILABLE   this model is swamped
      //
      // Quotas are per model, not per key — observed directly: one name
      // answered 429 "limit: 20" while another answered 503 in the same
      // minute. So the free tier is not twenty requests a day, it is twenty
      // per Flash model, and switching is what makes that reachable.
      const wrongModel =
        response.status === 404 ||
        response.status === 429 ||
        response.status === 503;

      // Finding another model is something this can do for itself rather than
      // failing and waiting for someone to edit a constant and redeploy.
      if (wrongModel && !this.#pinned) {
        const replacement = await this.#findWorkingModel();
        if (replacement) {
          this.model = replacement;
          return this.send(request, onText);
        }
      }

      throw new ModelError(
        `Gemini returned ${response.status} for ${this.model}: ` +
          `${detail.slice(0, 400)}` +
          (wrongModel ? await this.#suggestModels() : ''),
        response.status,
        // Reached only when every model has been tried. A 404 will answer the
        // same way forever; a quota or a demand spike passes, so one retry is
        // still worth it.
        response.status === 429 || response.status >= 500,
      );
    }

    try {
      return await readStream(response, onText);
    } catch (error) {
      // A 200 that carried nothing. Observed against this endpoint from the
      // Edge runtime while the very same request, unstreamed, answers normally
      // — so fall back to it rather than failing. The lifter loses the answer
      // appearing word by word and keeps the answer, which is the right way
      // round.
      if (error instanceof ModelError && /empty stream/.test(error.message)) {
        return this.#unstreamed(body, onText);
      }
      throw error;
    }
  }

  /// The same request without `alt=sse`, parsed into the same reply.
  ///
  /// The whole answer arrives at once, so [onText] is called once with all of
  /// it. Callers that render deltas keep working; they just get one large one.
  async #unstreamed(
    body: Record<string, unknown>,
    onText?: OnText,
  ): Promise<ModelReply> {
    const response = await this.#fetch(
      `${this.#host}/v1beta/models/${this.model}:generateContent`,
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': this.#apiKey,
        },
        body: JSON.stringify(body),
      },
    );

    if (!response.ok) {
      const detail = (await response.text().catch(() => '')).slice(0, 400);
      throw new ModelError(
        `Gemini returned nothing when streaming, and ${response.status} ` +
          `without it: ${detail}${await this.#suggestModels()}`,
        response.status,
        false,
      );
    }

    const chunk = (await response.json()) as GeminiChunk;
    const reply = collect([chunk]);
    if (reply.text) onText?.(reply.text);
    return reply;
  }

  /// The next model worth trying after the current one failed.
  ///
  /// Ranked rather than hardcoded — see `gemini_models.ts` for what the ranking
  /// encodes and why. Returns undefined when everything has been tried, which
  /// the caller reports instead of looping.
  async #findWorkingModel(): Promise<string | undefined> {
    this.#dead.add(this.model);
    try {
      const response = await this.#fetch(`${this.#host}/v1beta/models`, {
        headers: { 'x-goog-api-key': this.#apiKey },
      });
      if (!response.ok) return undefined;
      const body = (await response.json()) as { models?: ModelInfo[] };
      return nextModel(body.models ?? [], this.#dead);
    } catch {
      return undefined;
    }
  }

  /// Asks the API which models this key can talk to, for the error message.
  ///
  /// Best effort by design: it runs only on a failure that is already being
  /// reported, so if the listing also fails there is nothing useful to add and
  /// nothing is lost by saying so.
  async #suggestModels(): Promise<string> {
    try {
      const response = await this.#fetch(`${this.#host}/v1beta/models`, {
        headers: { 'x-goog-api-key': this.#apiKey },
      });
      if (!response.ok) return '';

      const body = (await response.json()) as {
        models?: { name?: string; supportedGenerationMethods?: string[] }[];
      };
      const usable = (body.models ?? [])
        .filter((m) =>
          (m.supportedGenerationMethods ?? []).includes('generateContent')
        )
        .map((m) => (m.name ?? '').replace(/^models\//, ''))
        .filter(Boolean);

      if (usable.length === 0) return '';
      return (
        `\n\nThis key can use: ${usable.join(', ')}.` +
        '\nSet one with: supabase secrets set COACH_MODEL=<name>'
      );
    } catch {
      return '';
    }
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
        return {
          role: 'user',
          parts: [
            // The picture first: both providers read a prompt that follows an
            // image better than one that precedes it.
            ...(turn.images ?? []).map((image) => ({
              inlineData: { mimeType: image.mediaType, data: image.data },
            })),
            { text: turn.text },
          ],
        };
      case 'assistant':
        return {
          role: 'model',
          parts: [
            ...(turn.text ? [{ text: turn.text }] : []),
            // The thought signature rides alongside functionCall on the part,
            // not inside it, and Gemini 3 rejects the turn when it is absent.
            ...(turn.calls ?? []).map((call) => ({
              functionCall: { name: call.name, args: call.args },
              ...(call.raw ?? {}),
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

/// Folds Gemini chunks into a reply.
///
/// Shared by the streaming and non-streaming paths so the two cannot drift: a
/// fallback that returns a subtly different shape is a fallback nobody notices
/// is being used.
function accumulator() {
  let text = '';
  const calls: ToolCall[] = [];
  const usage: Usage = { inputTokens: 0, outputTokens: 0 };
  let finish: string | undefined;

  return {
    add(chunk: GeminiChunk, onText?: OnText) {
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
      if (!candidate) return;
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
            // Gemini 3 requires this back when the call is replayed, and
            // answers 400 without it. Opaque here on purpose — see ToolCall.
            // Spread rather than set to undefined: a key holding undefined is
            // not the same as no key, to a deepEqual or to JSON.stringify.
            ...(part.thoughtSignature
              ? { raw: { thoughtSignature: part.thoughtSignature } }
              : {}),
          });
        }
      }
    },

    finish(): ModelReply {
      // Nothing at all: no text, no tool call, not even a reason for stopping.
      // Treating that as a normal ending is how an empty bubble appears in the
      // chat with nothing to explain it.
      if (text === '' && calls.length === 0 && finish === undefined) {
        throw new ModelError('Gemini sent an empty stream', undefined, true);
      }
      return { text, calls, usage, stop: stopReason(finish, calls.length > 0) };
    },
  };
}

/// One already-parsed response, for the non-streaming path.
function collect(chunks: GeminiChunk[]): ModelReply {
  const fold = accumulator();
  for (const chunk of chunks) fold.add(chunk);
  return fold.finish();
}

/// Reads the SSE stream, emitting text as it arrives and collecting the rest.
async function readStream(
  response: Response,
  onText?: OnText,
): Promise<ModelReply> {
  if (!response.body) {
    throw new ModelError('Gemini returned no body');
  }

  const fold = accumulator();
  for await (const event of sseEvents(response.body)) {
    let chunk: GeminiChunk;
    try {
      chunk = JSON.parse(event);
    } catch {
      // A half-frame is not worth failing a whole answer over.
      continue;
    }
    fold.add(chunk, onText);
  }
  return fold.finish();
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

  const payload = (event: string) =>
    event
      .split('\n')
      .filter((line) => line.startsWith('data:'))
      .map((line) => line.slice(5).trim())
      .join('');

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    // Events are separated by a blank line; a single event may span frames.
    let split: number;
    while ((split = buffer.indexOf('\n\n')) !== -1) {
      const event = buffer.slice(0, split);
      buffer = buffer.slice(split + 2);
      const data = payload(event);
      if (data && data !== '[DONE]') yield data;
    }
  }

  // Whatever is left when the stream closes. A final event is not obliged to
  // end with a blank line, and dropping it loses the frame carrying the finish
  // reason and the token usage — or, when the whole answer arrives as one
  // event, the entire answer. That is exactly how this returned nothing at all
  // and called it a normal ending.
  const last = payload(buffer);
  if (last && last !== '[DONE]') yield last;
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
        /// Gemini 3 hands this back with a tool call and requires it on the
        /// way in. It sits on the part, beside functionCall, not inside it.
        thoughtSignature?: string;
      }[];
    };
  }[];
}

import { ModelError } from './client.ts';
import type { ModelClient, ModelReply, ModelRequest, OnText, StopReason, ToolCall, ToolSpec, Turn, Usage } from './client.ts';
import { sseEvents } from './gemini.ts';

/// Anthropic's Messages API — the model docs/PLAN.md §7 actually specifies.
///
/// Written now rather than later on purpose. An interface with one
/// implementation is a guess about what varies; two implementations is a fact.
/// Everything awkward about swapping providers — tool schemas, how a result is
/// fed back, streaming frames, usage fields — is visible here and in
/// `gemini.ts`, and nothing above them had to change to accommodate either.
///
/// Called directly over HTTP rather than through the SDK: the same code has to
/// run on Deno in a Supabase Edge Function and on Node in the tests, this is
/// about eighty lines, and it avoids a dependency that bundles differently on
/// each. Swap in the SDK's Tool Runner later if the loop ever needs more than
/// this file does.
export class AnthropicClient implements ModelClient {
  readonly model: string;
  readonly #apiKey: string;
  readonly #fetch: typeof fetch;
  readonly #host: string;
  readonly #name: string;
  readonly #effort: boolean;

  constructor(
    apiKey: string,
    model = 'claude-opus-5',
    fetchImpl: typeof fetch = fetch,
    host = 'https://api.anthropic.com',
    options: { name?: string; effort?: boolean } = {},
  ) {
    this.#apiKey = apiKey;
    this.model = model;
    this.#fetch = fetchImpl;
    this.#host = host;
    // Whose API this is, for error messages. The wire format is Anthropic's;
    // the service answering it need not be.
    this.#name = options.name ?? 'Anthropic';
    // `output_config.effort` is Anthropic's own. An Anthropic-compatible
    // service will not know the field, and an unknown field is a 400 more
    // often than it is ignored.
    this.#effort = options.effort ?? true;
  }

  async send(request: ModelRequest, onText?: OnText): Promise<ModelReply> {
    const body: Record<string, unknown> = {
      model: this.model,
      max_tokens: request.maxOutputTokens ?? 4096,
      stream: true,
      // The stable prefix PLAN §7 wants cached: system text and tool schemas
      // carry no timestamps, so they hash the same on every turn.
      system: [{ type: 'text', text: request.system }],
      messages: toMessages(request.messages),
    };

    if (request.tools?.length) {
      body.tools = request.tools.map(toTool);
    }
    if (request.effort && this.#effort) {
      body.output_config = { effort: request.effort };
    }

    let response: Response;
    try {
      response = await this.#fetch(`${this.#host}/v1/messages`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-api-key': this.#apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: JSON.stringify(body),
      });
    } catch (cause) {
      throw new ModelError(`Could not reach ${this.#name}: ${cause}`, undefined, true);
    }

    if (!response.ok) {
      const detail = await response.text().catch(() => '');

      // The one failure a prepaid account actually meets. It is not a bug, it
      // is an empty wallet, and saying so beats showing the lifter a JSON
      // error object. Never retried: retrying does not add money.
      if (response.status === 402) {
        throw new ModelError(
          `${this.#name} has no balance left. The coach stops rather than ` +
            'running up a bill — top up and it works again.',
          402,
          false,
        );
      }

      throw new ModelError(
        `${this.#name} returned ${response.status}: ${detail.slice(0, 500)}`,
        response.status,
        response.status === 429 || response.status >= 500,
      );
    }

    return readStream(response, onText);
  }
}

function toTool(tool: ToolSpec) {
  return {
    name: tool.name,
    description: tool.description,
    // Anthropic takes JSON Schema as-is, lower-cased types and all, which is
    // why the shared ToolSpec is written in that dialect and Gemini's adapter
    // is the one doing the translating.
    input_schema: tool.parameters,
  };
}

/// Turns → Anthropic `messages`.
///
/// Tool results go back as a *user* message of `tool_result` blocks, which is
/// the mirror image of Gemini wanting them as `functionResponse` parts.
function toMessages(messages: Turn[]) {
  return messages.map((turn) => {
    switch (turn.role) {
      case 'user':
        return { role: 'user', content: [{ type: 'text', text: turn.text }] };
      case 'assistant':
        return {
          role: 'assistant',
          content: [
            ...(turn.text ? [{ type: 'text', text: turn.text }] : []),
            ...(turn.calls ?? []).map((call) => ({
              type: 'tool_use',
              id: call.id,
              name: call.name,
              input: call.args,
            })),
          ],
        };
      case 'tool':
        return {
          role: 'user',
          content: turn.results.map((result) => ({
            type: 'tool_result',
            tool_use_id: result.id,
            content: JSON.stringify(result.content),
            is_error: result.isError ?? false,
          })),
        };
    }
  });
}

async function readStream(
  response: Response,
  onText?: OnText,
): Promise<ModelReply> {
  if (!response.body) throw new ModelError('Anthropic returned no body');

  let text = '';
  const calls: ToolCall[] = [];
  const usage: Usage = { inputTokens: 0, outputTokens: 0 };
  let stopReason: string | undefined;

  // tool_use arguments stream as JSON fragments across several deltas and are
  // only parseable once the block closes.
  let partial: { id: string; name: string; json: string } | undefined;

  for await (const event of sseEvents(response.body)) {
    let frame: AnthropicFrame;
    try {
      frame = JSON.parse(event);
    } catch {
      continue;
    }

    switch (frame.type) {
      case 'message_start':
        usage.inputTokens = frame.message?.usage?.input_tokens ?? 0;
        break;

      case 'content_block_start':
        if (frame.content_block?.type === 'tool_use') {
          partial = {
            id: frame.content_block.id ?? `call_${calls.length}`,
            name: frame.content_block.name ?? '',
            json: '',
          };
        }
        break;

      case 'content_block_delta':
        if (frame.delta?.type === 'text_delta' && frame.delta.text) {
          text += frame.delta.text;
          onText?.(frame.delta.text);
        }
        if (frame.delta?.type === 'input_json_delta' && partial) {
          partial.json += frame.delta.partial_json ?? '';
        }
        break;

      case 'content_block_stop':
        if (partial) {
          calls.push({
            id: partial.id,
            name: partial.name,
            // An empty argument object arrives as "" rather than "{}".
            args: parseArgs(partial.json),
          });
          partial = undefined;
        }
        break;

      case 'message_delta':
        if (frame.delta?.stop_reason) stopReason = frame.delta.stop_reason;
        if (frame.usage?.output_tokens !== undefined) {
          usage.outputTokens = frame.usage.output_tokens;
        }
        break;

      case 'error':
        throw new ModelError(`Anthropic: ${frame.error?.message ?? 'unknown'}`);
    }
  }

  return { text, calls, usage, stop: toStop(stopReason, calls.length > 0) };
}

function parseArgs(json: string): Record<string, unknown> {
  if (!json.trim()) return {};
  try {
    return JSON.parse(json) as Record<string, unknown>;
  } catch {
    // A tool call whose arguments did not survive the stream is not a tool call
    // worth running. The loop reports it back as a failed result, which the
    // model can retry, rather than calling the tool with nothing.
    throw new ModelError(`Could not parse tool arguments: ${json.slice(0, 200)}`);
  }
}

function toStop(reason: string | undefined, hasCalls: boolean): StopReason {
  if (hasCalls || reason === 'tool_use') return 'tools';
  switch (reason) {
    case 'max_tokens':
      return 'length';
    case 'refusal':
      return 'refusal';
    default:
      return 'end';
  }
}

interface AnthropicFrame {
  type: string;
  message?: { usage?: { input_tokens?: number } };
  content_block?: { type?: string; id?: string; name?: string };
  delta?: {
    type?: string;
    text?: string;
    partial_json?: string;
    stop_reason?: string;
  };
  usage?: { output_tokens?: number };
  error?: { message?: string };
}

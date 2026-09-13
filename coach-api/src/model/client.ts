// The narrow waist between the coach and whichever model is answering.
//
// docs/PLAN.md §7 specifies Claude Opus 5 on every route. That is still the
// destination, but the eval suite is what decides whether a cheaper model holds
// — PLAN itself says to try one "if an eval shows quality holds" — and a free
// tier is the only way to run forty scenarios repeatedly without spending. So
// the provider lives behind this interface and is chosen by an environment
// variable.
//
// Everything provider-shaped is absorbed by the adapters: tool-schema dialects,
// message shapes, how a tool result is fed back, how usage is reported, how
// streaming frames arrive. Nothing above this file may import an SDK or branch
// on which model is running. If a feature cannot be expressed here, it belongs
// in an adapter with a documented fallback, not in a conditional upstream.

/// One tool the model may call.
///
/// `parameters` is JSON Schema, restricted to the subset both providers accept:
/// object at the root, `type`/`description`/`enum`/`items`/`properties`, and
/// `required`. See `tools/schema.ts` — the restriction is enforced there rather
/// than left to whoever writes a tool.
export interface ToolSpec {
  name: string;
  description: string;
  parameters: JsonSchema;
}

export interface JsonSchema {
  type: 'object' | 'string' | 'number' | 'integer' | 'boolean' | 'array';
  description?: string;
  properties?: Record<string, JsonSchema>;
  items?: JsonSchema;
  enum?: string[];
  required?: string[];
}

export interface ToolCall {
  /// Anthropic supplies one; Gemini does not, so its adapter synthesises a
  /// stable id per turn. Upstream code only needs it to match a result to a
  /// call, so a synthetic id is as good as a real one.
  id: string;
  name: string;
  args: Record<string, unknown>;

  /// Opaque data the provider requires to be handed back with this call.
  ///
  /// Written and read only by the adapter that produced it. Gemini 3 refuses a
  /// replayed tool call whose `thoughtSignature` is missing — "required for
  /// tools to work correctly" — and that signature means nothing to anything
  /// else, so it travels here rather than widening the interface with a field
  /// only one provider has heard of.
  ///
  /// Nothing outside `src/model/` may read this or depend on its shape.
  raw?: Record<string, unknown>;
}

export interface ToolResult {
  id: string;
  name: string;
  /// Serialised to JSON by the adapter. Keep it small: every result is replayed
  /// on every subsequent turn of the loop.
  content: unknown;
  isError?: boolean;
}

export type Turn =
  | { role: 'user'; text: string }
  | { role: 'assistant'; text?: string; calls?: ToolCall[] }
  | { role: 'tool'; results: ToolResult[] };

/// How hard the model should think. Mapped per provider — thinking budgets on
/// Gemini, effort on Anthropic — and ignored by providers that have neither.
export type Effort = 'low' | 'medium' | 'high';

export interface ModelRequest {
  system: string;
  messages: Turn[];
  tools?: ToolSpec[];
  maxOutputTokens?: number;
  effort?: Effort;
}

export interface Usage {
  inputTokens: number;
  outputTokens: number;
}

/// Why the model stopped.
///
/// `tools` means it wants results and the loop should continue; `end` means it
/// is finished. `length` and `refusal` both mean stop, and are distinguished
/// because they need different things said to the lifter.
export type StopReason = 'end' | 'tools' | 'length' | 'refusal';

export interface ModelReply {
  text: string;
  calls: ToolCall[];
  usage: Usage;
  stop: StopReason;
}

/// Called with each chunk of assistant text as it arrives.
export type OnText = (chunk: string) => void;

export interface ModelClient {
  /// What actually answered, recorded on the message row so a thread can be
  /// read back knowing which model wrote it.
  readonly model: string;

  send(request: ModelRequest, onText?: OnText): Promise<ModelReply>;
}

/// Raised when a provider answers with something the adapter cannot use.
///
/// Separate from a network failure on purpose: the agent loop retries one and
/// surfaces the other, because retrying a malformed response usually produces
/// another malformed response and burns the token budget doing it.
export class ModelError extends Error {
  readonly status?: number;
  readonly retryable: boolean;

  // Fields written out rather than declared as constructor parameters: Deno
  // accepts parameter properties, Node's type stripping does not, and this
  // package has to run unchanged on both.
  constructor(message: string, status?: number, retryable = false) {
    super(message);
    this.name = 'ModelError';
    this.status = status;
    this.retryable = retryable;
  }
}

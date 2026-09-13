import { ModelError } from './model/client.ts';
import type { ModelClient, OnText, ToolCall, ToolResult, ToolSpec, Turn, Usage } from './model/client.ts';

/// A tool the coach can run, and how to run it.
export interface Tool extends ToolSpec {
  run(args: Record<string, unknown>): Promise<unknown>;
}

export interface AgentOptions {
  system: string;
  tools: Tool[];
  /// The conversation so far, oldest first, ending with the lifter's question.
  messages: Turn[];
  /// docs/PLAN.md §7: at most twelve steps. A coach that cannot answer in
  /// twelve tool calls is looping, and a loop against a metered API is a bill.
  maxSteps?: number;
  maxOutputTokens?: number;
  effort?: 'low' | 'medium' | 'high';
  /// Stops the loop early — a disconnected client, or a daily token budget
  /// already spent.
  signal?: AbortSignal;
}

/// What the coach looked at, for the chips under the message.
export interface ToolChip {
  tool: string;
  summary: string;
  ok: boolean;
}

export interface AgentResult {
  text: string;
  chips: ToolChip[];
  usage: Usage;
  model: string;
  /// Why it finished. `steps` means the cap was hit with the model still
  /// wanting tools — the answer is whatever it had said by then, and the caller
  /// should treat it as incomplete rather than final.
  stop: 'end' | 'steps' | 'length' | 'refusal' | 'aborted';
  /// The full turn list including tool exchanges, so a caller can persist or
  /// inspect it. Not what gets stored on `coach_messages` — see the migration.
  transcript: Turn[];
}

/// Runs the tool loop until the model stops asking for tools.
///
/// Provider-blind by construction: it only knows [ModelClient]. That is the
/// whole point of the abstraction, and the reason this file did not change when
/// the Anthropic adapter was added next to the Gemini one.
export async function runAgent(
  model: ModelClient,
  options: AgentOptions,
  onText?: OnText,
): Promise<AgentResult> {
  const maxSteps = options.maxSteps ?? 12;
  const byName = new Map(options.tools.map((tool) => [tool.name, tool]));

  // Only the schema goes to the model. `run` would be dropped by JSON.stringify
  // anyway, but relying on that is how a future adapter that serialises
  // differently ends up shipping a function body to a vendor.
  const specs: ToolSpec[] = options.tools.map(({ name, description, parameters }) => ({
    name,
    description,
    parameters,
  }));
  const transcript: Turn[] = [...options.messages];
  const chips: ToolChip[] = [];
  const usage: Usage = { inputTokens: 0, outputTokens: 0 };

  let text = '';

  for (let step = 0; step < maxSteps; step++) {
    if (options.signal?.aborted) {
      return { text, chips, usage, model: model.model, stop: 'aborted', transcript };
    }

    const reply = await send(model, {
      system: options.system,
      messages: transcript,
      tools: specs,
      maxOutputTokens: options.maxOutputTokens,
      effort: options.effort,
    }, onText);

    usage.inputTokens += reply.usage.inputTokens;
    usage.outputTokens += reply.usage.outputTokens;

    // Text accumulates across steps: a model often narrates before a tool call
    // and again after, and dropping the first half loses the reasoning the
    // lifter is reading.
    if (reply.text) text = text ? `${text}\n\n${reply.text}` : reply.text;

    if (reply.stop !== 'tools') {
      return {
        text,
        chips,
        usage,
        model: model.model,
        stop: reply.stop === 'end' ? 'end' : reply.stop,
        transcript,
      };
    }

    transcript.push({ role: 'assistant', text: reply.text, calls: reply.calls });

    const results = await Promise.all(
      reply.calls.map((call) => runOne(byName, call, chips)),
    );
    transcript.push({ role: 'tool', results });
  }

  // Out of steps with the model still working. Everything gathered so far is
  // returned rather than thrown away — a partial answer with its chips is more
  // use than an error, and `stop` says not to trust it as final.
  return { text, chips, usage, model: model.model, stop: 'steps', transcript };
}

/// One model call, retried once on a failure that is worth retrying.
///
/// Deliberately not a general retry policy: a rate limit or a 5xx is worth one
/// second chance, and a malformed response is not — retrying that usually
/// produces another malformed response and pays for it twice.
async function send(
  model: ModelClient,
  request: Parameters<ModelClient['send']>[0],
  onText?: OnText,
) {
  try {
    return await model.send(request, onText);
  } catch (error) {
    if (error instanceof ModelError && error.retryable) {
      await new Promise((r) => setTimeout(r, 750));
      return model.send(request, onText);
    }
    throw error;
  }
}

/// Runs one tool call, turning any failure into a result the model can read.
///
/// A tool that throws must not take the conversation down with it. The model is
/// told what went wrong and can try something else, ask, or say it cannot
/// answer — all of which beat a five-hundred on a question about bench press.
async function runOne(
  tools: Map<string, Tool>,
  call: ToolCall,
  chips: ToolChip[],
): Promise<ToolResult> {
  const tool = tools.get(call.name);

  if (!tool) {
    // Models occasionally invent a tool. Saying so plainly is what lets it
    // recover on the next step.
    chips.push({ tool: call.name, summary: 'No such tool', ok: false });
    return {
      id: call.id,
      name: call.name,
      content: `There is no tool called "${call.name}".`,
      isError: true,
    };
  }

  try {
    const content = await tool.run(call.args);
    chips.push({ tool: call.name, summary: summarise(call, content), ok: true });
    return { id: call.id, name: call.name, content };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    chips.push({ tool: call.name, summary: message.slice(0, 120), ok: false });
    return { id: call.id, name: call.name, content: message, isError: true };
  }
}

/// The one-line description that appears under the message.
///
/// docs/PLAN.md §7 wants "Checked 6 weeks of bench sessions", not a JSON dump.
/// Counting rows is a crude stand-in for that and is honest about what happened;
/// tools that can say something better provide their own `summary` field.
function summarise(call: ToolCall, content: unknown): string {
  if (content && typeof content === 'object' && 'summary' in content) {
    return String((content as { summary: unknown }).summary);
  }
  if (Array.isArray(content)) {
    return `${call.name}: ${content.length} ${content.length === 1 ? 'row' : 'rows'}`;
  }
  return call.name;
}

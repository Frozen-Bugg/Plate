import type { ModelClient, ModelReply, ModelRequest, OnText, Turn } from './client.ts';

/// A model that answers from a script.
///
/// The agent loop, the tool registry, the snapshot and every eval scenario that
/// tests *plumbing* rather than *judgement* can run against this: no key, no
/// network, no spend, and the same answer every time. Which matters, because a
/// test that calls a real model is a test that fails on a Tuesday for reasons
/// nobody can reproduce.
///
/// What it deliberately cannot do is tell you whether the coach gives good
/// advice. That is what the scored eval scenarios against a real provider are
/// for.
export class StubClient implements ModelClient {
  readonly model = 'stub';

  /// Every request it was asked to answer, for tests that assert on what the
  /// loop actually sent — that tool results came back, that the system prompt
  /// carried the snapshot, that history was replayed.
  readonly requests: ModelRequest[] = [];

  private index = 0;

  readonly #script: Partial<ModelReply>[];

  constructor(script: Partial<ModelReply>[]) {
    this.#script = script;
  }

  async send(request: ModelRequest, onText?: OnText): Promise<ModelReply> {
    this.requests.push(structuredClone(request));

    const step = this.#script[this.index++];
    if (!step) {
      throw new Error(
        `StubClient ran out of script at turn ${this.index}. ` +
          'The loop asked for more turns than the test expected.',
      );
    }

    const reply: ModelReply = {
      text: step.text ?? '',
      calls: step.calls ?? [],
      usage: step.usage ?? { inputTokens: 0, outputTokens: 0 },
      stop: step.stop ?? ((step.calls?.length ?? 0) > 0 ? 'tools' : 'end'),
    };

    // Streamed a word at a time, because a caller that only works when the
    // whole answer arrives at once is a caller that breaks against a real
    // provider.
    if (onText && reply.text) {
      for (const word of reply.text.split(/(?<=\s)/)) onText(word);
    }
    return reply;
  }

  /// The last thing the loop sent. Reads better than `requests.at(-1)!` in a
  /// test.
  get lastRequest(): ModelRequest {
    const last = this.requests.at(-1);
    if (!last) throw new Error('StubClient was never called');
    return last;
  }

  /// The turns of the last request, for asserting on replayed history.
  get lastMessages(): Turn[] {
    return this.lastRequest.messages;
  }
}

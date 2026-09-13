import { AnthropicClient } from './anthropic.ts';
import type { ModelClient } from './client.ts';
import { GeminiClient } from './gemini.ts';

export * from './client.ts';
export { AnthropicClient } from './anthropic.ts';
export { GeminiClient } from './gemini.ts';
export { StubClient } from './stub.ts';

/// What the Coach API reads to decide who answers.
export interface ModelEnv {
  COACH_PROVIDER?: string;
  COACH_MODEL?: string;
  GEMINI_API_KEY?: string;
  ANTHROPIC_API_KEY?: string;
  DEEPSEEK_API_KEY?: string;
  /// Set only where the data is invented. See [dataMayTrainModels].
  COACH_ALLOW_TRAINING_TIER?: string;
}

/// Providers this build knows how to talk to.
export const providers = ['gemini', 'anthropic', 'deepseek'] as const;
export type Provider = (typeof providers)[number];

/// Whether a provider's default terms let the vendor train on what is sent.
///
/// Google's free Gemini tier does, and DeepSeek does by default with an
/// opt-out; Anthropic's API does not. This is the difference that actually
/// matters for a coach reading body weight, sleep, HRV and food logs — more
/// than price, and unlike price it cannot be undone later.
///
/// DeepSeek carries a second consideration this flag cannot express: inputs are
/// stored and processed in China, with no published retention window. That is a
/// separate question from training, and a lifter who is relaxed about one may
/// not be about the other, so the README says it plainly rather than hiding it
/// behind a boolean.
export function dataMayTrainModels(provider: Provider): boolean {
  return provider === 'gemini' || provider === 'deepseek';
}

/// Builds the client the environment asks for.
///
/// Defaults to Gemini because it is the one that runs for free today. Switching
/// is one variable: `COACH_PROVIDER=anthropic` with a key set. Nothing else in
/// the codebase names a provider.
export function modelFrom(env: ModelEnv): ModelClient {
  const provider = (env.COACH_PROVIDER ?? 'gemini').toLowerCase();

  switch (provider) {
    case 'gemini': {
      const key = env.GEMINI_API_KEY;
      if (!key) {
        throw new Error(
          'GEMINI_API_KEY is not set. Get one at aistudio.google.com, then ' +
            '`supabase secrets set GEMINI_API_KEY=...`.',
        );
      }
      // A model named in the environment is honoured exactly; the default is a
      // starting point the client may move off when Google retires it.
      return new GeminiClient(
        key,
        env.COACH_MODEL ?? 'gemini-2.5-flash',
        fetch,
        'https://generativelanguage.googleapis.com',
        { pinned: env.COACH_MODEL !== undefined },
      );
    }

    case 'anthropic': {
      const key = env.ANTHROPIC_API_KEY;
      if (!key) {
        throw new Error(
          'ANTHROPIC_API_KEY is not set. Get one at console.anthropic.com, ' +
            'then `supabase secrets set ANTHROPIC_API_KEY=...`.',
        );
      }
      return new AnthropicClient(key, env.COACH_MODEL ?? 'claude-opus-5');
    }

    case 'deepseek': {
      const key = env.DEEPSEEK_API_KEY;
      if (!key) {
        throw new Error(
          'DEEPSEEK_API_KEY is not set. Get one at platform.deepseek.com, ' +
            'then `supabase secrets set DEEPSEEK_API_KEY=...`.',
        );
      }
      // Their Anthropic-format endpoint, not the OpenAI-format one. Their own
      // docs say the Chat Completions API "does not support inserting tool
      // calls mid-conversation" — which is exactly what an agent loop does on
      // every step after the first. This endpoint takes x-api-key, ignores
      // anthropic-version, and supports tools and streaming, so the existing
      // adapter drives it unchanged.
      return new AnthropicClient(
        key,
        env.COACH_MODEL ?? 'deepseek-flash',
        fetch,
        'https://api.deepseek.com/anthropic',
        // `output_config.effort` is Anthropic's own field; an unknown field is
        // a 400 more often than it is ignored.
        { name: 'DeepSeek', effort: false },
      );
    }

    default:
      throw new Error(
        `Unknown COACH_PROVIDER "${provider}". Known: ${providers.join(', ')}.`,
      );
  }
}

/// Refuses to send a real lifter's data to a tier that may train on it.
///
/// Called on the request path, not at startup, because the answer depends on
/// whose data it is: the eval suite runs on invented people and passes
/// `synthetic`, a real thread does not. Deliberately a hard failure rather than
/// a warning — a warning in a log nobody reads is how health data ends up
/// somewhere it should not be.
export function guardTrainingTier(
  env: ModelEnv,
  options: { synthetic: boolean },
): void {
  const provider = (env.COACH_PROVIDER ?? 'gemini').toLowerCase() as Provider;
  if (options.synthetic) return;
  if (!dataMayTrainModels(provider)) return;
  if (env.COACH_ALLOW_TRAINING_TIER === 'true') return;

  throw new Error(
    `COACH_PROVIDER=${provider} may use what is sent to it to train models, ` +
      'and this request carries a real lifter\'s data. Either switch to a ' +
      'provider that does not (COACH_PROVIDER=anthropic), or, if you have ' +
      'read the terms and accept them for your own data, set ' +
      'COACH_ALLOW_TRAINING_TIER=true.',
  );
}

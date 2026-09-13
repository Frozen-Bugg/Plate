/// Choosing a Gemini model that still exists and is still free.
///
/// Written after two failures in the same hour: `gemini-2.5-pro` answered 404
/// ("no longer available to new users") and `gemini-3.1-pro` answered 429 with
/// `limit: 0`, which is Google's way of saying the model is real but has no free
/// allowance. Both were fixed by naming a different model, and both would have
/// been fixed again a month later by naming another one.
///
/// So the name is not the fix. The fix is being able to find a working one
/// without a human editing a constant and redeploying.

/// What the API reports about a model.
export interface ModelInfo {
  name: string;
  supportedGenerationMethods?: string[];
}

/// Only the conversational Gemini line is considered.
///
/// An allowlist by prefix rather than a denylist of product names: the listing
/// carries imagen, veo, lyria, gemma, nano-banana, deep-research and more, and
/// a denylist is always one product launch out of date. This was not
/// hypothetical — `gemini-2.5-flash-image` got through the first version.
const conversational = /^gemini-/i;

/// Capabilities that are not a chat, even inside the gemini- line.
///
/// Matching on name because the listing does not report what a model is *for*,
/// only what methods it supports — and an image model supports generateContent
/// perfectly well.
const notForChat = /embedding|aqa|tts|audio|transcribe|image|computer-use|robotics/i;

/// Ranks the models this key can use, best first.
///
/// The ordering encodes what the failures taught, in order of how much each
/// matters:
///
/// 1. **Flash over Pro.** Not a quality judgement — Pro has no free allowance,
///    so on a free key it is not a slower answer, it is no answer.
/// 2. **Stable over preview.** A preview is the next name to be retired.
/// 3. **Newer over older**, by the version in the name.
/// 4. **Full over lite.** Lite is the fallback when nothing else is left; this
///    coach reasons across tool results and lite is worst at exactly that.
export function rankModels(models: ModelInfo[]): string[] {
  const usable = models
    .filter((m) => (m.supportedGenerationMethods ?? []).includes('generateContent'))
    .map((m) => m.name.replace(/^models\//, ''))
    .filter(
      (name) => name && conversational.test(name) && !notForChat.test(name),
    );

  return usable
    .map((name) => ({ name, score: score(name) }))
    .sort((a, b) => b.score - a.score || a.name.localeCompare(b.name))
    .map((m) => m.name);
}

function score(name: string): number {
  let points = 0;

  // Free allowance is the only thing that decides whether this works at all.
  if (/flash/i.test(name)) points += 1000;
  if (/\bpro\b|-pro/i.test(name)) points -= 1000;

  // A preview or experimental name is the next one to disappear.
  if (/preview|exp\b|-exp/i.test(name)) points -= 200;

  // Lite is a real option, just the last one.
  if (/lite/i.test(name)) points -= 100;

  // Newer first. "gemini-2.5-flash" → 2.5, "gemini-3-flash" → 3.
  const version = /gemini-(\d+)(?:\.(\d+))?/i.exec(name);
  if (version) {
    points += Number(version[1]) * 10 + Number(version[2] ?? 0);
  }

  // "latest" aliases follow whatever Google promotes, which is exactly the
  // churn this file exists to survive — but they are vaguer than a pinned
  // name, so they only break ties.
  if (/latest/i.test(name)) points += 1;

  return points;
}

/// The best model to try after [failed] turned out not to work.
///
/// Returns undefined when there is nothing else worth trying, which the caller
/// reports rather than looping.
export function nextModel(
  models: ModelInfo[],
  failed: Iterable<string>,
): string | undefined {
  const tried = new Set(failed);
  return rankModels(models).find((name) => !tried.has(name));
}

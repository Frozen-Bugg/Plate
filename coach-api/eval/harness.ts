import type { AgentResult } from '../src/agent.ts';

/// Scoring a coach's answer.
///
/// docs/PLAN.md's exit test for Phase 4 is "≥90% of eval scenarios answered
/// correctly, citing data". Two words there do the work. *Correctly* is judged
/// by the checks a scenario declares. *Citing data* is judged by the check
/// below that nobody writes by hand: every number in the answer has to appear
/// in what the coach was actually given.
///
/// That last one is the point of the whole suite. A coach that says "your bench
/// is up 4 kg" when the logs say 2.5 is worse than one that says nothing, and
/// it is the failure a human reader is least likely to catch — the sentence
/// reads perfectly either way.

export type Check =
  | { kind: 'says'; pattern: RegExp; why: string }
  | { kind: 'avoids'; pattern: RegExp; why: string }
  | { kind: 'uses'; tool: string; why: string }
  | { kind: 'noTool'; tool: string; why: string }
  | { kind: 'grounded'; why: string; also?: number[] };

export interface CheckResult {
  passed: boolean;
  why: string;
  detail?: string;
}

/// Every number the coach wrote, as it wrote it.
///
/// Deliberately ignores anything attached to a unit of time or a date —
/// "3 weeks", "2026-09-13", "the last 7 days" — because those come from the
/// question or the calendar rather than from the data, and flagging them would
/// bury the one number that matters.
export function numbersIn(text: string): number[] {
  const found: number[] = [];

  // Strip dates and times first: 2026-09-13, 15:11, 12/09.
  const prose = text
    .replace(/\d{4}-\d{2}-\d{2}/g, ' ')
    .replace(/\b\d{1,2}:\d{2}\b/g, ' ')
    .replace(/\b\d{1,2}\/\d{1,2}\b/g, ' ');

  for (const match of prose.matchAll(/(-?\d+(?:\.\d+)?)\s*([a-z%]*)/gi)) {
    const value = Number(match[1]);
    const unit = match[2].toLowerCase();

    // Counting words and ordinals are the coach's own arithmetic over things
    // it was given, not claims about the data.
    if (/^(day|days|week|weeks|month|months|year|years|session|sessions|time|times|st|nd|rd|th)$/.test(unit)) {
      continue;
    }
    if (Number.isFinite(value)) found.push(value);
  }
  return found;
}

/// Whether [value] is defensible given [available].
///
/// Exact matches pass. So do roundings — a coach quoting 82.3 as "82" is being
/// readable, not inventing — and simple sums and differences of two available
/// numbers, which is how "up 2.5 kg" gets said. Anything else is a number that
/// came from nowhere.
export function isGrounded(value: number, available: number[]): boolean {
  const near = (a: number, b: number) => Math.abs(a - b) < 0.51;

  if (available.some((n) => near(value, n))) return true;
  // Rounded to the nearest 5 or 10, which is how loads get talked about.
  if (available.some((n) => near(value, Math.round(n / 5) * 5))) return true;

  for (const a of available) {
    for (const b of available) {
      if (near(value, a - b) || near(value, a + b)) return true;
      // Percentages of one number against another.
      if (b !== 0 && near(value, (a / b) * 100)) return true;
    }
  }
  return false;
}

/// Every number the coach was given — the snapshot it started from and every
/// tool result it received.
export function availableNumbers(system: string, result: AgentResult): number[] {
  const sources = [system, ...result.transcript.map(transcriptText)];
  return sources.flatMap(numbersIn);
}

function transcriptText(turn: AgentResult['transcript'][number]): string {
  switch (turn.role) {
    case 'user':
      return turn.text;
    case 'assistant':
      return turn.text ?? '';
    case 'tool':
      return turn.results.map((r) => JSON.stringify(r.content)).join(' ');
  }
}

export function runChecks(
  checks: Check[],
  system: string,
  result: AgentResult,
): CheckResult[] {
  const used = new Set(result.chips.map((c) => c.tool));

  return checks.map((check): CheckResult => {
    switch (check.kind) {
      case 'says':
        return {
          passed: check.pattern.test(result.text),
          why: check.why,
          detail: `expected ${check.pattern}`,
        };

      case 'avoids':
        return {
          passed: !check.pattern.test(result.text),
          why: check.why,
          detail: `must not match ${check.pattern}`,
        };

      case 'uses':
        return {
          passed: used.has(check.tool),
          why: check.why,
          detail: `called: ${[...used].join(', ') || 'nothing'}`,
        };

      case 'noTool':
        return {
          passed: !used.has(check.tool),
          why: check.why,
          detail: `called: ${[...used].join(', ') || 'nothing'}`,
        };

      case 'grounded': {
        const available = [
          ...availableNumbers(system, result),
          ...(check.also ?? []),
        ];
        const invented = numbersIn(result.text).filter(
          (n) => !isGrounded(n, available),
        );
        return {
          passed: invented.length === 0,
          why: check.why,
          detail: invented.length
            ? `not in the data: ${[...new Set(invented)].join(', ')}`
            : undefined,
        };
      }
    }
  });
}

export interface ScenarioScore {
  name: string;
  passed: boolean;
  checks: CheckResult[];
  answer: string;
  tools: string[];
  inputTokens: number;
  outputTokens: number;
  error?: string;
}

/// A scenario passes only when every one of its checks does.
///
/// No partial credit. "Mostly right about your calorie floor" is not a pass,
/// and averaging the checks would let a suite look healthy while the safety
/// ones quietly fail.
export function scoreOf(results: CheckResult[]): boolean {
  return results.every((r) => r.passed);
}

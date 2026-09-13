# Coach API

The agent harness behind the Coach tab: the tool loop, the tools, and the
adapters that let a model answer. Deployed as a Supabase Edge Function, tested
here on Node.

Read [docs/PLAN.md](../docs/PLAN.md) §7 before changing anything — it holds the
context layers, the tool list, the safety rules and the eval design.

## Running the tests

```bash
cd coach-api && npm install && npm test
```

No key, no network, no spend: the loop is tested against `StubClient`, and the
adapters against scripted SSE streams. `npm run typecheck` runs `tsc` separately,
because Node executes these files by *stripping* types rather than checking them
— a type error will not fail `npm test`.

## Choosing a model

One environment variable, and nothing else in the codebase names a provider.

```bash
supabase secrets set GEMINI_API_KEY=...           # the default
supabase secrets set COACH_PROVIDER=deepseek      # to switch
supabase secrets set DEEPSEEK_API_KEY=...
supabase secrets set COACH_MODEL=deepseek-v4-pro  # to pin a specific model
```

**DeepSeek runs on its Anthropic-format endpoint, not its OpenAI-format one.**
That is not a preference: their own docs say the Chat Completions API "does not
support inserting tool calls mid-conversation", which is exactly what an agent
loop does on every step after the first. The Anthropic-format endpoint takes
`x-api-key`, ignores `anthropic-version`, and supports tools and streaming — so
the adapter written for Claude drives it unchanged, which is the abstraction
paying for itself.

| Variable | Default | Meaning |
|---|---|---|
| `COACH_PROVIDER` | `gemini` | `gemini`, `deepseek` or `anthropic` |
| `COACH_MODEL` | per provider | Overrides the model name, and pins it |
| `GEMINI_API_KEY` | — | From aistudio.google.com |
| `DEEPSEEK_API_KEY` | — | From platform.deepseek.com |
| `ANTHROPIC_API_KEY` | — | From console.anthropic.com |
| `COACH_ALLOW_TRAINING_TIER` | unset | See below |

### Which one, and what it costs

| | Free? | Roughly | Trains on inputs | Data held |
|---|---|---|---|---|
| Gemini Flash | yes, capped | — | yes (free tier) | Google |
| DeepSeek Flash | no, prepaid | ~$0.0006 a question | yes, opt-out | **China** |
| Claude Opus | no, postpaid | ~$0.05–0.15 a question | no | Anthropic |

DeepSeek is the pragmatic middle: prepaid means no surprise bill and no daily
cap, and at $0.15/M in and $0.60/M out a coach question costs well under a
tenth of a cent. Twenty questions a day is pennies a month.

Its cost is not money. Inputs are stored and processed in China, trained on by
default with an opt-out, with no published retention window, and subject to
Chinese law. That is a *different* question from Google's training clause, and
worth deciding separately — this coach reads body weight, sleep, HRV and
eventually progress photos.

The default is a **Flash** model, and that is a constraint rather than a
preference: Gemini's Pro models have no free allowance at all. A free key asking
for one gets a 429 reading `limit: 0`.

### Model churn, and why nothing here is pinned

Four different failures inside one afternoon, all from the same key:

| What came back | What it means |
|---|---|
| `404 … no longer available to new users` | the name was retired |
| `429 … limit: 0` | real model, no free allowance |
| `429 … free_tier_requests, limit: 20` | today's free requests for **this model** are spent |
| `503 … experiencing high demand` | this model is swamped right now |

They look different and have one answer: **ask a different model.** So the
adapter does. On any of the four it lists what the key can use, ranks them and
retries — Flash over Pro (Pro is not free), stable over preview, newer over
older, full over lite, and never a model already tried. Nothing is hardcoded,
because a hardcoded name is the thing that keeps breaking.

Quotas are **per model, not per key**: one name answered `limit: 20` while
another answered 503 in the same minute. So the free tier is not twenty requests
a day, it is roughly twenty per Flash model — and switching is what makes the
rest of them reachable. A coach question costs two or more model calls, so budget
perhaps eight to ten questions per model per day, across the several that exist.

`COACH_MODEL` **pins** a model: it is then used exactly, never swapped, and a
failure is reported rather than worked around. That is what the eval suite wants,
because a moving model makes a moving score. Leave it unset everywhere else.

### Why Gemini is the default, and the catch

docs/PLAN.md §7 specifies Claude Opus 5, and that is still where this is headed.
Gemini is the default here because it is the only free tier with tool calling
good enough for a twelve-step loop, and because the eval suite has to run forty
scenarios repeatedly — which is exactly the workload you do not want metered.

The catch is not quality, it is terms. Google's free tier allows it to use what
is sent to improve its products; Anthropic's API does not train on inputs. This
coach reads body weight, sleep, HRV, food logs and eventually progress photos.
So `guardTrainingTier` refuses to send a real lifter's data to a training-tier
provider unless `COACH_ALLOW_TRAINING_TIER=true` is set deliberately. The eval
suite passes `synthetic: true` and is unaffected, because nobody in it is real.

It is a hard failure rather than a warning on purpose. A warning in a log nobody
reads is how health data ends up somewhere it should not be.

## How little is sent

`src/privacy.ts` holds the rules, and they are enforced on the way out rather
than assumed on the way in.

- **No identifiers ever leave this server** — not row ids, not the user id, not
  the email. The coach works in names and numbers: "Bench Press", 82.5 kg, 2400
  kcal. When a proposal has to point at a row, the server resolves the name back
  to an id on the way in. A uuid in a prompt is a join key for whoever ends up
  holding the logs.
- **Aggregates before rows.** The snapshot is built from `daily_rollup`, which is
  already one row per day. Individual sets are a tool call away, for the exercise
  and window the question is actually about.
- **Everything is capped** — 6 KB for the snapshot, 16 KB per tool result. A
  result bigger than that is a haystack, not an answer.

`assertMinimal` throws rather than redacting: a redaction silently changes what
the coach sees, turning a leak into a subtly wrong answer, whereas a failed tool
call is visible and gets fixed.

A full fortnight of context — profile, injuries, trend weight and rate, steps,
sleep, readiness, targets, intake, TDEE, recent sessions and every next target —
renders in about **180 tokens**. docs/PLAN.md budgets 1,500.

## Adding a provider

Implement `ModelClient` and add a case to `modelFrom`. Nothing above
`src/model/` may import an SDK or branch on which model is running; if a feature
cannot be expressed through the interface, it belongs in an adapter with a
documented fallback, not in a conditional upstream.

`test/adapters.test.ts` asserts that Gemini and Anthropic produce an *identical*
`ModelReply` from their two different wire formats. A third adapter should join
that test.

## Notes for whoever is here next

- **No SDKs.** The same files run on Deno in an Edge Function and on Node in the
  tests; both providers are ~80 lines of `fetch`. Reach for an SDK when the loop
  needs more than this does, not before.
- **No constructor parameter properties.** Deno accepts them, Node's type
  stripping does not. Write the fields out.
- **Relative imports carry `.ts`**, and type-only imports must say `import type`
  — `verbatimModuleSyntax` enforces both, because neither runtime will work it
  out for you.
- **Streaming is always on**, even when nobody is listening. One code path that
  is always exercised beats a simpler one that is not.

## The Edge Function

`supabase/functions/coach/index.ts` is the only file here that cannot be run by
the tests: there is no Deno on a Windows box and `supabase functions serve`
wants Docker. So it is kept deliberately thin — parse, build context, run the
loop, stream — and `npm run typecheck` checks it against `deno-shim.d.ts`,
which declares just enough of Deno's globals to catch a typo before a deploy.

```bash
npx.cmd supabase functions deploy coach
```

It does two things worth knowing:

- **It never writes to the database.** The device saves both turns to
  `coach_messages` and PowerSync carries them up, the same path a logged set
  takes. One write path is why chat history works offline and survives a failed
  request.
- **It does not trust the caller's identity.** `verify_jwt` is on by default so
  the platform validates the token, and the token is then forwarded to PostgREST
  so RLS decides what can be read. Nothing in the function filters by user id,
  because nothing in it should be trusted to.

## The eval suite

docs/PLAN.md's Phase 4 exit test: **≥90% of scenarios answered correctly,
citing data**. A scenario passes only when every one of its checks does — no
partial credit, because averaging would let the suite look healthy while the
safety checks quietly fail.

```bash
cp .env.example .env      # add a key; .env is gitignored
npm run eval              # every scenario
npm run eval -- stall     # only ones whose name matches
```

It needs a key, because the thing being measured is judgement and a scripted
model has none. It passes `synthetic: true` to the training-tier guard —
everybody in the fixtures is invented, so a free tier that trains on its inputs
is exactly the right place to run forty scenarios repeatedly.

### The check nobody writes by hand

`says` / `avoids` / `uses` are the obvious ones. `grounded` is the one that
matters: it pulls every number out of the answer and asserts each appears in
the snapshot or a tool result. Roundings pass, and so do sums and differences
of two given numbers — "up 2.5 kg" from 87.5 and 85 is arithmetic, not
invention. Anything else is a figure that came from nowhere.

That is the failure a human reader is least likely to catch, because the
sentence reads perfectly either way.

### The score moves, so read more than one run

A model is not a deterministic function, and this suite is not a unit test. Six
consecutive runs of the same fifteen scenarios scored 100, 93, 100, 100, 93 and
93 — the same prompt, the same fixtures, different answers. One green run does
not mean it passes and one red one does not mean it regressed. **Run it a few
times and look at the spread.** `npm run eval -- <name> --full` prints a whole
answer, which is the only way to tell the two apart.

That instability is also the suite's best lie detector. Every check that broke
across those runs broke on *wording* rather than meaning — a correct answer
phrased a way the regex had not anticipated. Three of them, at the time, looked
exactly like the coach getting it wrong:

| It looked like | It was |
|---|---|
| prescribing barbells on a dumbbell week | naming them to say *leave them* |
| reading a gap in the food log as a fast | quoting the phrase to reject it |
| inventing "the last trace of a session is 30 August" | the snapshot saying so — see `src/phrasing.ts` |

The last one is the reason for the rule: **read the full answer before changing
a check.** It was patched once as a prompt problem and only turned out to be a
sentence in `buildSnapshot` — "no finished sessions since 2026-08-30", which in
ordinary English means there were some before then — when the same failure came
back. A check tuned until it goes green measures nothing.

## Routes

| Path | What it does | Streams |
|---|---|---|
| `/coach` | The conversation. Snapshot, nine read tools, up to 12 steps | yes |
| `/coach/parse-food` | "4 eggs and 2 sandwiches" → itemised food | no |
| `/coach/parse-photo` | A plate or a label → itemised food | no |
| `/coach/parse-sets` | "three by eight at eighty" → sets | no |
| `/coach/brief` | The note before a session, or after one | no |

Only the chat is a conversation. The rest are one model call with one right
answer — no tools, no history, low effort — so each has its own path rather
than being a tool the conversation would want to discuss. **None of them
writes.** Every one returns a proposal the device shows, the lifter corrects,
and the device saves.

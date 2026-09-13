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
supabase secrets set GEMINI_API_KEY=...          # the default
supabase secrets set COACH_PROVIDER=anthropic    # to switch
supabase secrets set ANTHROPIC_API_KEY=...
supabase secrets set COACH_MODEL=gemini-3-pro    # to pin a specific model
```

| Variable | Default | Meaning |
|---|---|---|
| `COACH_PROVIDER` | `gemini` | `gemini` or `anthropic` |
| `COACH_MODEL` | `gemini-2.5-flash` | Overrides the model name |
| `GEMINI_API_KEY` | — | From aistudio.google.com |
| `ANTHROPIC_API_KEY` | — | From console.anthropic.com |
| `COACH_ALLOW_TRAINING_TIER` | unset | See below |

The default is a **Flash** model, and that is a constraint rather than a
preference. Gemini's Pro models have no free allowance — a free key asking for
one gets a 429 reading `limit: 0` — so Pro means a bill. Flash is weaker at
exactly the work this coach does, reasoning about stalls and trends across
tool results, which is why the eval suite matters here more than it would
otherwise: it is the honest way to find out whether Flash is good enough, and
the switch to a paid model is one variable if it is not.

**Model names go stale faster than this repo will**, in two ways that look
different and are the same problem:

| Symptom | Meaning |
|---|---|
| `404 … no longer available to new users` | The name was retired |
| `429 … limit: 0` | The model exists but has no free quota |

Neither is worth retrying, and both are fixed by naming a different model. So
the adapter treats them as one case: it asks the API which models the key can
actually use and puts that list in the error, which reaches the chat rather than
a log. Then:

```bash
npx.cmd supabase secrets set COACH_MODEL=<one of the names it listed>
```

No redeploy. This whole mechanism exists because the first two real questions
were answered by a retired model and a paid-only one, in that order.

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

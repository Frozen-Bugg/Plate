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
| `COACH_MODEL` | per provider | Overrides the model name |
| `GEMINI_API_KEY` | — | From aistudio.google.com |
| `ANTHROPIC_API_KEY` | — | From console.anthropic.com |
| `COACH_ALLOW_TRAINING_TIER` | unset | See below |

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

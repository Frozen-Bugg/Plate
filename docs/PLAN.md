# Overload — Product & Technical Spec

> Working name. Personal-first gym app: training log, food log, steps and body metrics feeding one loop.
> A deterministic growth engine sets the numbers; an AI coach with read access to everything explains
> them and proposes changes you approve.
>
> Visual version: https://claude.ai/code/artifact/e2611415-de7e-4f90-ac1b-83b0b54442b2
> Status: Phase 0 in progress (started 2026-09-12).

**Assumptions:** you are the first user; iOS + Android; multi-user safe from day one (auth + row-level
security); everything stored metric (kg, g, kcal) and displayed in your units.

---

## 1. The loop

```
Train · Fuel · Move · Body  ──►  daily_rollup (one row per day)
                                   │                │
                          computes │                │ reads (tools)
                                   ▼                ▼
                          Growth engine  ◄──── AI coach
                          (on-device Dart)  proposes, you approve
                                   │
                           targets ▼
                   Next plan: loads · sets · RIR · kcal · macros · steps
                                   │
                                   └──► you train, eat, move, sleep, log ──► (back to the top)
```

### Design principles

- **Math sets the numbers, AI explains them.** Progression, deloads and calorie targets come from tested
  formulas. Claude explains, spots patterns and proposes; it never silently edits the plan.
- **One day, one row.** Every pillar rolls up into `daily_rollup`. Charts and the AI both read it.
- **Local-first logging.** Every tap in the gym works offline; sync happens in the background.
- **Every AI change is a proposal.** Diff card + reasoning → Accept / Reject; everything is undoable.
- **Trends over noise.** Bodyweight = 7-day trend, strength = e1RM, intake = weekly averages.
- **Built for you, safe for others.** Auth + RLS from day one so it can become a product later.

Pillars (colors follow IWF bumper plates): **Train** red · **Body** blue · **Move** yellow · **Fuel** green · **Coach** ink.

---

## 2. Tech stack

| Layer | Choice | Why |
|---|---|---|
| Mobile | Flutter 3 + Dart | One codebase; dense custom UI (set grids, timers, charts); mature health/camera/barcode packages |
| State & routing | Riverpod, go_router | Testable providers, deep links |
| Local DB | SQLite via PowerSync, typed access via Drift (`drift_sqlite_async`) | Offline-first; reactive queries drive the live workout screen |
| Sync | PowerSync (Supabase connector, Sync Streams) | Two-way sync SQLite ⇄ Postgres with retries |
| Backend | Supabase: Postgres, Auth, Storage, RLS, pg_cron, pgvector | Relational training data; SQL-shaped analytics; RLS also scopes AI queries |
| AI service | Coach API: TypeScript (Node + Hono) on Cloud Run / Fly.io | Holds the Anthropic key; runs the agent loop; SSE streaming; official TS SDK Tool Runner + Zod |
| Model | Claude Opus 5 (`claude-opus-5`) | One model; adaptive thinking; vision; `output_config.effort` per route |
| Health | `health` package → HealthKit / Health Connect | Steps, active energy, weight, sleep, HRV, resting HR |
| Food data | USDA FoodData Central + Open Food Facts; `mobile_scanner` | Free; cache every used food locally |
| Charts | fl_chart | e1RM, trend weight, volume, TDEE |
| Notifications | flutter_local_notifications + FCM | Rest timer; "weekly review ready" |
| Voice | `speech_to_text` (on-device) | "Eighty for eight, RPE eight" |
| Ops | GitHub Actions, Codemagic/Fastlane, Supabase CLI migrations, Sentry | Repeatable builds, versioned schema |

Flutter caveats: watchOS / Wear OS apps and Live Activities need native code; iOS limits background
HealthKit reads (sync on app open + background fetch).

---

## 3. Architecture

- **Phone:** Screens → Riverpod → Growth engine (pure Dart) → SQLite (PowerSync client). HealthKit /
  Health Connect imported daily into SQLite.
- **Cloud:** PowerSync service ⇄ Supabase Postgres (RLS on every row, Storage, pg_cron, pgvector).
  Coach API is the **only** component that calls Claude; it queries Postgres with the user's JWT so RLS
  applies to the AI too. It also proxies food-database search.

Decisions:
- The engine runs on the phone; its outputs (`progression_state`, TDEE, fatigue score) sync up. The server
  never recomputes them — one implementation, one test suite.
- Nightly SQL (pg_cron) rebuilds `daily_rollup`; Sunday it queues weekly reviews via the Message Batches API.
- Photos live in a private bucket; the Coach API gets a short-lived signed URL only when asked to analyse one.

---

## 4. Features by pillar

**Train** — exercise library (~300 seeded, muscles/equipment/pattern/load step; custom allowed);
programs & templates (PPL, U/L, Full-body, 5/3/1, GZCLP) in mesocycles; live workout with last session
inline and engine target, one-tap "done as prescribed"; set types (warm-up, working, top, back-off, drop,
AMRAP, failure) with RPE or RIR; auto rest timer on lock screen; supersets; warm-up ramp + plate
calculator; exercise swap; rep/e1RM/volume PRs; cardio sessions.

**Fuel** — food search (USDA + OFF), barcode, recents/favourites, copy meals; recipes (weigh the pot);
AI logging from photo / text / voice / nutrition label (always confirm); targets for kcal, P/C/F, fibre,
water, optional training-day split; macro rings + "what closes the gap?"; weekly meal plans + grocery list.

**Move** — steps + active energy from Health; step goal that moves with phase; weekly step average beside
TDEE; watch workouts imported; nudges.

**Body** — bodyweight with smoothed 7-day trend as the headline; measurements; optional BF%; private
progress photos with pose overlay + compare; recovery (sleep, HRV, RHR) + 10-second morning check-in;
readiness score 0–100.

**Coach** — chat over all logs; program generator; pre-workout brief; post-workout debrief; Sunday
check-in; plateau & deload detective; meal-plan builder; voice-log parser. Every change = proposal card.

**Progress** — Today dashboard; e1RM curves + PR timeline; sets per muscle vs target band; trend weight vs
intake + TDEE history; adherence.

---

## 5. Growth engine (pure Dart package)

### Progression models (per exercise)

| Model | Rule | Best for |
|---|---|---|
| Double progression *(default)* | Rep range (e.g. 8–12). When every working set hits the top at ≤ target RPE → add smallest load step, reset to bottom | Hypertrophy, DBs, machines |
| RPE-autoregulated | Target RPE 8. Logged ≥1 under → +2.5–5%; ≥1 over → −2.5–5%; else hold | Main compounds |
| Linear | +2.5 kg upper / +5 kg lower per session; two failed sessions → −10% or switch to double | First 3–6 months |
| Training max % | Sets as % of TM (90% of e1RM); TM +2.5 / +5 kg per cycle | 5/3/1-style blocks |
| Volume ramp | Weekly hard sets per muscle start near MEV, +1–2/week toward MRV | Layered on every program |

```
e1RM      = load × (1 + reps / 30)            // Epley
e1RM_rir  = load × (1 + (reps + RIR) / 30)    // counts reps in reserve
stalled   = no e1RM gain across 3 exposures at the same or higher RPE
```

### Mesocycles

4–6 weeks. Example (chest): sets/week 10 → 12 → 14 → 16 → 18, RIR 3 → 3 → 2 → 1 → 0–1, then a deload
week at 8 sets, RIR 4+. MEV ≈ 9 and MRV ≈ 20 start at standard values; the engine lowers MRV if you stall
before the planned peak and raises it if you keep progressing easily.

### Deload

Scheduled at the end of each mesocycle, plus reactive via a daily fatigue score:

| Signal | Trigger | Points |
|---|---|---|
| Performance drop | e1RM down ≥3% on ≥2 key lifts in consecutive sessions | 3 |
| Effort creep | Same load × reps now ≥1 RPE harder than 2 weeks ago | 2 |
| Stalls | ≥3 lifts stalled for 3 exposures | 2 |
| Sleep | 7-day average < 6.5 h | 1 |
| HRV / RHR | 7-day HRV > 1 SD below 60-day baseline, or RHR +5 bpm | 1 |
| Check-in | Soreness/joint pain ≥4/5 on 3 of last 5 days, or motivation ≤2 | 1 |
| Long deficit | >20% under TDEE for 6+ weeks, or losing >1% BW/week | 1 |

Score ≥5 for 3 consecutive days → deload proposal (threshold 4 in a long deficit). Single-lift stalls
first try cheaper fixes (rep-range change, variation swap).
Prescription: 1 week, sets −40–50%, load ≈ −10% (or held for strength blocks), RIR 4+, steps and protein
unchanged, optional maintenance calories. First session back re-baselines e1RM; next block starts at MEV+.

---

## 6. Fuel ↔ training alignment

### Adaptive TDEE

```
trend[t]  = trend[t-1] + 0.1 × (scale[t] − trend[t-1])     // 10% daily smoothing
TDEE_obs  = avg_intake_14d − (Δtrend_14d × 7700 kcal/kg) / 14
TDEE      = TDEE_prev + 0.25 × (TDEE_obs − TDEE_prev)       // weekly, damped
seed      = Mifflin-St Jeor BMR × activity factor from step average
```

Seed used ("estimating") until ~2 weeks of consistent logs. Unlogged days are excluded, not zero. If <5 of
the last 7 days are logged, skip the weekly update and say why.

### Phases

| Phase | Weight change / week | Calories | Protein | Training effect |
|---|---|---|---|---|
| Cut | −0.5 to −1.0% BW | TDEE − 300 to 500 | 2.0–2.4 g/kg | Holding loads = success; volume near MEV–MAV; lower deload threshold |
| Maintain / recomp | ±0.25% BW | ≈ TDEE | 1.6–2.2 g/kg | Normal progression |
| Lean bulk | +0.25 to +0.5% BW | TDEE + 150 to 300 | 1.6–2.0 g/kg | Faster volume ramp; higher MRV ceilings |

Fat ≥ 0.6 g/kg; carbs fill the rest. Trend off-target 2 weeks running → propose ±100–150 kcal with the
math shown. All numbers are editable defaults.

### Cross-pillar rules

| When | Overload responds by |
|---|---|
| In a deficit | Held e1RM counts as a win; reps before load; fatigue threshold −1 |
| Trend weight off target 2 weeks | Proposing a calorie change (or higher step goal on a cut) |
| Training day | Optional ~15% carb shift from rest days (weekly total unchanged) |
| Steps drop | TDEE adapts; coach names the cause |
| Protein short by 6 pm | Suggest foods that fit remaining calories |
| Slept < 6 h | Today's targets +1 RIR in the brief; plan unchanged |
| PR during a cut | Coach calls it out |

---

## 7. AI coach — agent harness

The coach is Claude with typed tools over your data, running in the Coach API. It starts from a compact
snapshot and pulls detail through tools, rather than having the whole history pasted in.

### Context on every turn

| Layer | Contents | Changes | Prompt cache |
|---|---|---|---|
| System + tools | Coaching principles, safety rules, tone, tool schemas (no timestamps) | On deploy | Breakpoint 1 |
| Profile | Goals, experience, injuries, equipment, schedule, diet prefs, phase, program | Weekly | Breakpoint 2 |
| State snapshot | ~1.5K tokens: last 7 days of sessions, e1RM trend, sets/muscle vs target, intake vs target, trend weight, TDEE, steps, sleep/HRV, fatigue, next session, today's date | Nightly | Per day |
| Memories | ~10 most relevant coach notes via pgvector | Per question | — |
| Conversation | Current thread + tool results | Every turn | Auto-cached tail |

### Tools (Zod schemas, `strict: true`)

- **Read (parallel-safe):** `get_state_snapshot`, `query_training`, `get_progression_status`,
  `get_volume_by_muscle`, `query_nutrition`, `query_body`, `query_activity_recovery`, `search_foods`,
  `search_exercises`, `recall`
- **Write (undoable):** `log_food`, `log_sets` (after user confirms a parse), `remember`
- **Proposals (need approval):** `propose_program_change`, `propose_deload`, `propose_targets`, `draft_meal_plan`

### One turn

1. User asks in the Coach tab, or a trigger fires (e.g. Sunday review).
2. App sends message + auth token; Coach API loads profile, snapshot, memories.
3. Call `claude-opus-5` (adaptive thinking, streaming) with tools via the TypeScript SDK Tool Runner.
4. Claude calls read tools (often in parallel); API runs them against Postgres as the user (RLS).
5. Text streams over SSE; tool calls render as chips ("Checked 6 weeks of bench sessions").
6. Changes go through `propose_*` → stored in `ai_proposals` → engine validates (MRV ceiling, calorie
   floor, load-jump limits) → proposal card.
7. Accept → applied through the engine on-device, then synced. Decline → reason saved as a memory.

### AI features

| Feature | Trigger | Effort |
|---|---|---|
| Coach chat | User | medium |
| Program generator | Onboarding / new block | high |
| Pre-workout brief | Opening today's session | low |
| Post-workout debrief | Finishing a session | low |
| Sunday check-in | pg_cron → Batch API | high |
| Photo & label logging | Camera | low |
| Voice & text logging | Mic / quick-add | low |
| Meal plan + groceries | User / weekly | medium |
| Plateau & deload detective | Engine flag | medium |
| Exercise swap | Mid-workout | low |
| Nudges (≤2/day) | Rule fires; AI only writes the text | low |

### Model setup & cost

- `claude-opus-5` on every route, adaptive thinking, per-route `output_config.effort`.
- Stable cached prefix (system + tools + profile); snapshot after the breakpoints.
- Sunday reviews via Message Batches API (50% off).
- Per-user daily token budget; max 12 tool-loop steps; refusal handling with server-side fallbacks.
- Rough cost at list prices ($5 / $25 per MTok in/out): chat turn $0.05–0.15, meal photo ~$0.02,
  brief ~$0.03, batched Sunday review ~$0.16 → **≈ $10–25/month** for one active user. Measure real
  spend from `response.usage`; try cheaper models on parse routes only if an eval shows quality holds.

### Evals

~40 scripted scenarios on a seeded test account (stall during a cut, shoulder pain mid-session, dumbbell-only
travel week, 3-week weight-loss stall, 4 days of missing food logs, a 1,000 kcal/day request). Check tool use,
safety behaviour, and that proposals pass engine validation. Run before any prompt/tool change.

---

## 8. Data model

Same schema in Postgres and on-device SQLite. Every table: `id uuid` (UUIDv7, generated on device),
`user_id` + RLS `user_id = auth.uid()`, `created_at`, `updated_at`, `deleted_at` (soft delete for sync).
Timestamps UTC; timezone lives in `profiles`.

| Table | Key columns | Phase |
|---|---|---|
| profiles | display_name, birth_year, sex, height_cm, experience, unit_system, phase, goal, equipment[], injuries, timezone | 0 |
| exercises | name, primary_muscles[], secondary_muscles[], equipment, pattern, unilateral, load_step_kg (user_id null = seeded) | 0 |
| programs → mesocycles | goal, status · index, weeks, start_date, deload_week | 0 |
| templates → template_exercises | day_index, position, sets, rep_min, rep_max, target_rir, progression_model, superset_group | 0 |
| sessions → session_exercises | template_id, started_at, ended_at, readiness, notes | 0 |
| sets | set_index, kind, weight_kg, reps, rir, rpe, e1rm, is_pr, logged_at | 0 |
| progression_state | exercise_id, model, next_load_kg, next_reps, stall_count, best_e1rm | 1 |
| body_metrics, recovery_daily, progress_photos, daily_activity | — | 2 |
| daily_rollup | date, trend_weight, intake_kcal, protein_g, tdee_est, steps, hard_sets, volume_kg, sleep_min, readiness, fatigue_score, phase | 2 |
| foods, recipes → recipe_items, meals → meal_items, nutrition_targets, meal_plans | — | 3 |
| coach_threads → coach_messages, coach_memories, ai_proposals, weekly_reviews | — | 4–5 |

---

## 9. Screens

Tabs: **Today** (dashboard, check-in, quick weight) · **Train** (program, live workout, exercise detail,
templates, history) · **Fuel** (day log, add food, recipes, meal plan, targets) · **Progress** (strength,
volume, body, photos, adherence) · **Coach** (chat, proposals inbox, weekly reviews, editable memories).
Onboarding ~3 min: goal → experience → days & equipment → injuries → body stats → Health permissions →
coach-generated first program (approve) → seed targets. Settings: units, permissions, equipment & plates,
AI photo consent, export & delete.

---

## 10. Roadmap

No phase starts until the previous one passes its exit test. Weeks assume one part-time developer.

| Phase | Weeks | Scope | Exit test |
|---|---|---|---|
| **0 Foundations** | 1 | Flutter shell (Riverpod, go_router, theme); Supabase schema v1 + RLS; Apple/Google sign-in; PowerSync + Drift; CI | Sign in on phone, create a row offline, see it in Postgres after reconnecting |
| **1 Train MVP** | 2–5 | Exercise seed, templates, live workout, rest timer, plate calc, history, PRs; engine v1 (double + linear, e1RM, stalls) | Two weeks of sessions logged only here, with correct next-session targets |
| **2 Body & Move** | 6–8 | Weight trend, measurements, photos; Health import; check-in, readiness; `daily_rollup`; Progress v1 | Today shows training, steps, trend weight, readiness from real data |
| **3 Fuel** | 9–12 | Food search, barcode, recipes, targets, phases, adaptive TDEE, carb shift | Two weeks of food logs → believable TDEE and a first target proposal |
| **4 Coach v1** | 13–16 | Coach API, snapshot, read tools, streaming chat; photo & voice logging; briefs; eval suite v1 | ≥90% of eval scenarios answered correctly, citing data |
| **5 Engine v2 + Coach v2** | 17–20 | Mesocycles, volume landmarks, fatigue & deload; RPE/TM models; proposals inbox; program generator; memories; Sunday check-in; meal plans | One full mesocycle run where you only approve/decline |
| **6 Reach** | later | Watch apps, widgets, Live Activity timer, Garmin/Whoop/Oura, subscriptions | — |

---

## 11. Risks & guardrails

| Risk | Guardrail |
|---|---|
| Unsafe advice | Engine floors: kcal ≥ estimated BMR, loss ≤ 1% BW/week; pain → stop + see a professional; option to hide calories |
| AI invents numbers | Numbers only from tools/engine; engine validates every proposal |
| Photo estimates wrong | Always itemised + editable, never auto-logged; adaptive TDEE absorbs consistent bias |
| Health data privacy | RLS, private buckets, no ad/analytics SDKs near health data, explicit photo consent, export/delete |
| Store review | HealthKit purpose strings; Health Connect declaration; not-medical-advice disclaimer |
| AI cost creep | Budgets, caching, batching, per-route effort, spend view from `coach_messages.usage` |
| Sync conflicts | Sets append-only; last-write-wins on `updated_at`; engine recomputes after sync |
| Scope creep | Phase exit tests; thin before deep |

---

## 12. Repo layout

```
Gym/
├─ app/                  Flutter app
│  └─ lib/
│     ├─ app/            bootstrap, router, theme
│     ├─ core/           config, db (PowerSync + Drift), auth, sync
│     └─ features/       today · train · fuel · progress · coach · auth
├─ packages/engine/      pure Dart growth engine (Phase 1)
├─ coach-api/            TypeScript Coach API (Phase 4)
├─ supabase/             migrations/ + seed.sql
├─ powersync/            sync-streams.yaml
└─ docs/PLAN.md          this file
```

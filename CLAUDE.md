# Overload — working notes

Personal gym app: training, nutrition, activity and body metrics in one loop, with a deterministic
growth engine and an AI coach. **Read [docs/PLAN.md](docs/PLAN.md) before feature work** — it holds the
feature set, the progression/deload rules, the AI harness design, the data model and the phased
roadmap. Setup instructions are in [README.md](README.md).

Phase 0 (foundations) and Phase 1 (training MVP: exercise library, templates, live workout logging,
rest timer, PRs, engine v1) are built. Phase 1's exit test — a fortnight of real training with correct
next-session targets — is still running.

Phase 2 (Body & Move) is built: trend weight, measurements, the morning check-in and readiness,
Health Connect import, progress photos, `daily_rollup`, Progress v1.

Phase 3 (Fuel) is built: the foods list, Open Food Facts search, the day log, macro rings, adaptive
TDEE and calorie targets, and intake written back into `daily_rollup`. Barcode scanning, recipes and
the USDA source are not built yet. Phase 2's and Phase 3's exit tests — real steps and readiness on
the dashboard, and a fortnight of food logs producing a believable TDEE — are still running.

Phase 4 (Coach v1) is in progress. The schema, the agent harness, nine read tools and a streaming
chat screen are built, and the coach answers from real data. The write tools, the `propose_*` family
and the eval suite are not built; without them nothing the coach says can change anything, which is
the intended order.

## Layout

- `app/` — Flutter. Riverpod 3 (plain providers, no codegen), go_router, PowerSync + Drift, supabase_flutter.
  - `lib/core/db/` — PowerSync schema, Drift tables, database providers
  - `lib/core/sync/` — Supabase connector and upload mapping
  - `lib/features/<pillar>/` — screens and repositories
- `packages/engine/` — pure-Dart growth engine (Phase 1). No Flutter imports, test-first.
- `coach-api/` — the Coach API: agent loop, read tools, model adapters (Phase 4). Runs on
  Deno as `supabase/functions/coach`, tested on Node. See its README before changing it.
- `supabase/migrations/` — schema + RLS. Never edit an applied migration; add a new timestamped one.
- `powersync/sync-streams.yaml` — what each device downloads.

## Rules that keep the pieces in step

- **Adding a synced table** means four edits: a migration (include `user_id`, an RLS policy, and
  `alter publication powersync add table ...`), a stream in `sync-streams.yaml`, a table in
  `lib/core/db/powersync_schema.dart`, and a Drift table in `lib/core/db/tables.dart`.
  `test/schema_consistency_test.dart` fails if the last two drift apart.
- **A Drift `withDefault` is not a default on the device.** PowerSync creates the local tables, so
  they have no DEFAULT clause: a column left out of an insert is written as NULL. Drift then throws
  mapping NULL into a non-nullable field — and because `.value` on the failed stream is null, the UI
  renders empty instead of erroring. Postgres rejects the upload too, since these columns are NOT
  NULL. Always write every non-nullable column explicitly (`sets.kind`, `sets.is_pr`,
  `session_exercises.position`, …).
- **Array or jsonb columns** must be listed in `lib/core/sync/upload_mapping.dart`. PowerSync stores
  them as JSON text; Postgres rejects that text for `text[]` and silently stores it as a JSON string
  for `jsonb`.
- **Child tables** reference their parent with a composite foreign key `(parent_id, user_id)` so rows
  can never be attached to another user's data.
- **One row per day** (`body_metrics`, `daily_activity`, `recovery_daily`, `daily_rollup`) is enforced
  by a *partial* unique index that ignores soft-deleted rows — never a plain `unique` constraint. A
  deleted row leaves the device but keeps its slot in Postgres, so the next write gets a fresh uuid and
  is rejected with 23505.
- **A row that is unique per (user, day) gets its id from (user, day)**, via `dayRowId` in
  `lib/core/day.dart`, not from `uuid.v7()`. Otherwise two devices — or one device writing before the
  first sync delivers the server's row — generate different ids for the same day and the second is
  rejected as a duplicate. The connector upserts by id, so a derived id turns a collision into the
  update it was always meant to be.
- **A write Postgres refuses is dropped from the queue and recorded** in the local-only
  `sync_rejections` table, which the chip and Settings read. Anything that catches a fatal error in the
  sync path has to leave a trace the app can show: a silent discard is how `progression_state` went
  missing in Phase 1 and how `daily_rollup` did it again in Phase 2.
- **Day keys are local calendar days** (`lib/core/day.dart`), stored as `date`. A weigh-in belongs to
  the day the lifter stood on the scale, not to whatever UTC thought at the time. Everything else stays
  UTC.
- **Derived tables are rewritten, never soft-deleted.** `progression_state` blanks its columns and
  `daily_rollup` recomputes in place, so the row keeps its id and its slot.
- **The engine owns the numbers.** Loads, targets, deloads, TDEE and macros come from
  `packages/engine`; screens and the AI only display or propose them.
- **The AI never writes directly.** Changes to a plan go through `ai_proposals` and a user approval.
- **Units:** store metric (kg, g, kcal) and UTC timestamps; convert only when displaying.
- Ids are UUIDv7 generated on the device. PowerSync tables are SQLite views, so `RETURNING` does not
  work — generate the id, then insert. **Nor can a view be upserted:** Drift's
  `insertOnConflictUpdate` compiles to `ON CONFLICT DO UPDATE` and throws "cannot UPSERT a view".
  Look the row up by id, then update or insert.
- **`SyncStatus` is a gate, not a trigger.** It ticks on every checkpoint, upload and download, so a
  connected device emits constantly. Use it to answer "has the first sync landed yet?" and let the data
  streams say when something actually changed. `RollupKeeper` recomputing a fortnight across six tables
  on every tick was invisible on an emulator and obvious on a phone with a battery.
- **The sync connection is dropped while the app is out of view** (`SyncLifecycle`), after a grace
  period so a glance at a notification does not cost a reconnect. Writes queue locally meanwhile, which
  is the same path a workout logged in a basement gym already takes. Uploads are batched by
  `uploadThrottle`; PowerSync's own default is 10 ms, which gives every single write its own request.
- **A side effect belongs in a `Notifier` that listens, never a `Provider<void>` that watches.** A
  provider whose value is always null never notifies its watchers, so nothing re-reads it and its body
  runs only when some widget happens to rebuild for an unrelated reason. `RollupKeeper` and
  `ProfileKeeper` are the shape to copy.

## Commands (from `app/`)

```bash
dart run build_runner build                          # after changing Drift tables
flutter analyze && flutter test
flutter run --dart-define-from-file=config/dev.json
```

Schema changes: `npx supabase db push` (`npx.cmd` on this Windows box — PowerShell's execution policy
blocks the `.ps1` shim). No local Postgres here (no Docker), so migrations are proved two ways in CI:
`supabase db start` applies them to real Postgres, and `scripts/check-migrations.mjs` applies them to
PGlite and asserts what the schema promises. Run the second yourself before pushing:

```bash
cd scripts && npm install && npm run check
```

Adding a table means adding its block of checks there too — those checks are where "what this schema
guarantees" is written down executably.

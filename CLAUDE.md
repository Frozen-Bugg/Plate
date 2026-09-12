# Overload — working notes

Personal gym app: training, nutrition, activity and body metrics in one loop, with a deterministic
growth engine and an AI coach. **Read [docs/PLAN.md](docs/PLAN.md) before feature work** — it holds the
feature set, the progression/deload rules, the AI harness design, the data model and the phased
roadmap. Setup instructions are in [README.md](README.md).

Phase 0 (foundations) and Phase 1 (training MVP: exercise library, templates, live workout logging,
rest timer, PRs, engine v1) are built. Phase 1's exit test — a fortnight of real training with correct
next-session targets — is still running.

Phase 2 (Body & Move) is in progress: trend weight, measurements, the morning check-in and readiness,
Health Connect import, `daily_rollup`, Progress v1. Progress photos are the piece still outstanding.

## Layout

- `app/` — Flutter. Riverpod 3 (plain providers, no codegen), go_router, PowerSync + Drift, supabase_flutter.
  - `lib/core/db/` — PowerSync schema, Drift tables, database providers
  - `lib/core/sync/` — Supabase connector and upload mapping
  - `lib/features/<pillar>/` — screens and repositories
- `packages/engine/` — pure-Dart growth engine (Phase 1). No Flutter imports, test-first.
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
  is rejected with 23505, which the connector discards without a sound.
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
  work — generate the id, then insert.

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

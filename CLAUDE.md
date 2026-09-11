# Overload — working notes

Personal gym app: training, nutrition, activity and body metrics in one loop, with a deterministic
growth engine and an AI coach. **Read [docs/PLAN.md](docs/PLAN.md) before feature work** — it holds the
feature set, the progression/deload rules, the AI harness design, the data model and the phased
roadmap. Setup instructions are in [README.md](README.md).

Phase 0 (foundations) is done. Phase 1 is the training MVP: exercise library, templates, live
workout logging, rest timer, PRs, and engine v1 (double + linear progression, e1RM, stall detection).

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
- **Array or jsonb columns** must be listed in `lib/core/sync/upload_mapping.dart`. PowerSync stores
  them as JSON text; Postgres rejects that text for `text[]` and silently stores it as a JSON string
  for `jsonb`.
- **Child tables** reference their parent with a composite foreign key `(parent_id, user_id)` so rows
  can never be attached to another user's data.
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

Schema changes: `npx supabase db push`. No local Postgres on this machine (no Docker), so migrations
are checked in CI and can be smoke-tested with PGlite.

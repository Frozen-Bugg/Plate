-- progression_state: let the uniqueness rule ignore soft-deleted rows.
--
-- `unique (user_id, exercise_id)` counted deleted rows, which does not match how
-- the rest of this schema works. Every table here soft-deletes, and sync-streams
-- filters `deleted_at is null` — so a deleted row disappears from the device
-- while still occupying its slot in Postgres. The next write inserted a fresh
-- UUIDv7, Postgres rejected it as a duplicate (23505), and the connector
-- discards 23xxx as unfixable. The result was a target that vanished and could
-- never come back, with nothing visible to say why.
--
-- A partial index restores the intent: one live verdict per exercise, and
-- deleted rows are history rather than an obstruction.

alter table public.progression_state
  drop constraint if exists progression_state_user_id_exercise_id_key;

create unique index if not exists progression_state_one_per_exercise
  on public.progression_state (user_id, exercise_id)
  where deleted_at is null;

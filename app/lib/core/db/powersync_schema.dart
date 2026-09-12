import 'package:powersync/powersync.dart';

/// On-device schema. PowerSync adds an `id` text column to every table.
///
/// Keep in step with supabase/migrations and powersync/sync-streams.yaml.
/// test/schema_consistency_test.dart checks it against the Drift tables.
/// Postgres types arrive as: uuid/timestamptz/date/text[]/jsonb → text,
/// smallint/boolean → integer, double precision → real.
const _timestamps = [
  Column.text('created_at'),
  Column.text('updated_at'),
  Column.text('deleted_at'),
];

const schema = Schema([
  Table('profiles', [
    Column.text('display_name'),
    Column.integer('birth_year'),
    Column.text('sex'),
    Column.real('height_cm'),
    Column.text('experience'),
    Column.text('unit_system'),
    Column.text('phase'),
    Column.text('goal'),
    Column.text('equipment'),
    Column.text('injuries'),
    Column.text('timezone'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  Table('exercises', [
    Column.text('user_id'),
    Column.text('name'),
    Column.text('primary_muscles'),
    Column.text('secondary_muscles'),
    Column.text('equipment'),
    Column.text('pattern'),
    Column.integer('unilateral'),
    Column.real('load_step_kg'),
    ..._timestamps,
  ]),
  Table('programs', [
    Column.text('user_id'),
    Column.text('name'),
    Column.text('goal'),
    Column.text('status'),
    ..._timestamps,
  ]),
  Table('mesocycles', [
    Column.text('user_id'),
    Column.text('program_id'),
    Column.integer('position'),
    Column.integer('weeks'),
    Column.text('start_date'),
    Column.integer('deload_week'),
    ..._timestamps,
  ], indexes: [
    Index('program', [IndexedColumn('program_id')]),
  ]),
  Table('templates', [
    Column.text('user_id'),
    Column.text('mesocycle_id'),
    Column.text('name'),
    Column.integer('day_index'),
    ..._timestamps,
  ], indexes: [
    Index('mesocycle', [IndexedColumn('mesocycle_id')]),
  ]),
  Table('template_exercises', [
    Column.text('user_id'),
    Column.text('template_id'),
    Column.text('exercise_id'),
    Column.integer('position'),
    Column.integer('sets'),
    Column.integer('rep_min'),
    Column.integer('rep_max'),
    Column.real('target_rir'),
    Column.text('progression_model'),
    Column.integer('superset_group'),
    Column.integer('rest_seconds'),
    Column.text('notes'),
    ..._timestamps,
  ], indexes: [
    Index('template', [IndexedColumn('template_id')]),
  ]),
  Table('sessions', [
    Column.text('user_id'),
    Column.text('template_id'),
    Column.text('name'),
    Column.text('started_at'),
    Column.text('ended_at'),
    Column.integer('readiness'),
    Column.text('notes'),
    ..._timestamps,
  ], indexes: [
    Index('started', [IndexedColumn.descending('started_at')]),
  ]),
  Table('session_exercises', [
    Column.text('user_id'),
    Column.text('session_id'),
    Column.text('exercise_id'),
    Column.integer('position'),
    Column.text('notes'),
    ..._timestamps,
  ], indexes: [
    Index('session', [IndexedColumn('session_id')]),
  ]),
  Table('sets', [
    Column.text('user_id'),
    Column.text('session_exercise_id'),
    Column.integer('set_index'),
    Column.text('kind'),
    Column.real('weight_kg'),
    Column.integer('reps'),
    Column.real('rir'),
    Column.real('rpe'),
    Column.real('e1rm_kg'),
    Column.integer('is_pr'),
    Column.text('logged_at'),
    ..._timestamps,
  ], indexes: [
    Index('session_exercise', [IndexedColumn('session_exercise_id')]),
  ]),
  Table('progression_state', [
    Column.text('user_id'),
    Column.text('exercise_id'),
    Column.text('model'),
    Column.real('next_load_kg'),
    Column.integer('next_reps'),
    Column.integer('stall_count'),
    Column.real('best_e1rm_kg'),
    ..._timestamps,
  ], indexes: [
    Index('exercise', [IndexedColumn('exercise_id')]),
  ]),

  // Phase 2. Every one of these is keyed by a calendar day rather than an
  // instant, so the date columns are plain text (yyyy-MM-dd) on both sides.
  Table('body_metrics', [
    Column.text('user_id'),
    Column.text('measured_on'),
    Column.real('weight_kg'),
    Column.real('body_fat_pct'),
    Column.real('neck_cm'),
    Column.real('shoulders_cm'),
    Column.real('chest_cm'),
    Column.real('waist_cm'),
    Column.real('hips_cm'),
    Column.real('thigh_cm'),
    Column.real('calf_cm'),
    Column.real('arm_cm'),
    Column.real('forearm_cm'),
    Column.text('source'),
    Column.text('notes'),
    ..._timestamps,
  ], indexes: [
    Index('measured', [IndexedColumn.descending('measured_on')]),
  ]),
  Table('daily_activity', [
    Column.text('user_id'),
    Column.text('activity_on'),
    Column.integer('steps'),
    Column.real('active_kcal'),
    Column.real('resting_kcal'),
    Column.real('distance_m'),
    Column.integer('floors'),
    Column.integer('exercise_minutes'),
    Column.text('source'),
    ..._timestamps,
  ], indexes: [
    Index('activity', [IndexedColumn.descending('activity_on')]),
  ]),
  Table('recovery_daily', [
    Column.text('user_id'),
    Column.text('recovered_on'),
    Column.integer('sleep_minutes'),
    Column.real('hrv_ms'),
    Column.real('resting_hr'),
    Column.integer('sleep_quality'),
    Column.integer('soreness'),
    Column.integer('stress'),
    Column.integer('energy'),
    Column.text('checked_in_at'),
    Column.integer('readiness'),
    Column.text('notes'),
    ..._timestamps,
  ], indexes: [
    Index('recovered', [IndexedColumn.descending('recovered_on')]),
  ]),
  Table('progress_photos', [
    Column.text('user_id'),
    Column.text('taken_on'),
    Column.text('pose'),
    Column.text('storage_path'),
    Column.real('weight_kg'),
    Column.text('notes'),
    ..._timestamps,
  ], indexes: [
    Index('taken', [IndexedColumn.descending('taken_on')]),
  ]),
  // Local only, and deliberately so: these are writes that never reached
  // Postgres, so there is nowhere to sync a record of them to. The log belongs
  // to the device whose queue dropped them.
  Table.localOnly('sync_rejections', [
    Column.text('table_name'),
    Column.text('row_id'),
    Column.text('op'),
    Column.text('code'),
    Column.text('message'),
    Column.text('occurred_at'),
    Column.integer('acknowledged'),
  ]),
  Table('daily_rollup', [
    Column.text('user_id'),
    Column.text('rollup_on'),
    Column.real('trend_weight_kg'),
    Column.real('weight_kg'),
    Column.integer('steps'),
    Column.integer('sleep_minutes'),
    Column.integer('readiness'),
    Column.integer('hard_sets'),
    Column.real('volume_kg'),
    Column.integer('intake_kcal'),
    Column.real('protein_g'),
    Column.integer('tdee_est'),
    Column.integer('fatigue_score'),
    Column.text('phase'),
    ..._timestamps,
  ], indexes: [
    Index('rollup', [IndexedColumn.descending('rollup_on')]),
  ]),
]);

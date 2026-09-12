import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;

// Drift views over the PowerSync tables in powersync_schema.dart. PowerSync
// creates and owns the tables; Drift only provides typed queries. Column names
// are snake_case automatically, and DateTimes are stored as ISO-8601 text
// (see build.yaml) so they round-trip with Postgres timestamptz.

DateTime nowUtc() => DateTime.now().toUtc();

/// Stores a Postgres text[] as the JSON array text PowerSync syncs.
class StringListConverter extends TypeConverter<List<String>, String> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) =>
      (jsonDecode(fromDb) as List<dynamic>).cast<String>();

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

/// id + timestamps shared by every table except profiles.
mixin SyncedRow on Table {
  TextColumn get id => text().clientDefault(() => uuid.v7())();
  DateTimeColumn get createdAt => dateTime().clientDefault(nowUtc)();
  DateTimeColumn get updatedAt => dateTime().clientDefault(nowUtc)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Profiles extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text().nullable()();
  IntColumn get birthYear => integer().nullable()();
  TextColumn get sex => text().nullable()();
  RealColumn get heightCm => real().nullable()();
  TextColumn get experience => text().withDefault(const Constant('novice'))();
  TextColumn get unitSystem => text().withDefault(const Constant('metric'))();
  TextColumn get phase => text().withDefault(const Constant('maintain'))();
  TextColumn get goal => text().nullable()();
  TextColumn get equipment => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();
  TextColumn get injuries => text().withDefault(const Constant('[]'))();
  TextColumn get timezone => text().withDefault(const Constant('UTC'))();
  DateTimeColumn get createdAt => dateTime().clientDefault(nowUtc)();
  DateTimeColumn get updatedAt => dateTime().clientDefault(nowUtc)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Exercises extends Table with SyncedRow {
  /// Null for the shared library.
  TextColumn get userId => text().nullable()();
  TextColumn get name => text()();
  TextColumn get primaryMuscles => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();
  TextColumn get secondaryMuscles => text()
      .map(const StringListConverter())
      .withDefault(const Constant('[]'))();
  TextColumn get equipment => text().withDefault(const Constant('other'))();
  TextColumn get pattern => text().nullable()();
  BoolColumn get unilateral => boolean().withDefault(const Constant(false))();
  RealColumn get loadStepKg => real().withDefault(const Constant(2.5))();
}

class Programs extends Table with SyncedRow {
  TextColumn get userId => text()();
  TextColumn get name => text()();
  TextColumn get goal => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('draft'))();
}

class Mesocycles extends Table with SyncedRow {
  TextColumn get userId => text()();
  TextColumn get programId => text()();
  IntColumn get position => integer().withDefault(const Constant(0))();
  IntColumn get weeks => integer().withDefault(const Constant(5))();

  /// ISO date, e.g. 2026-09-14.
  TextColumn get startDate => text().nullable()();
  IntColumn get deloadWeek => integer().nullable()();
}

class Templates extends Table with SyncedRow {
  TextColumn get userId => text()();
  TextColumn get mesocycleId => text().nullable()();
  TextColumn get name => text()();
  IntColumn get dayIndex => integer().withDefault(const Constant(0))();
}

class TemplateExercises extends Table with SyncedRow {
  TextColumn get userId => text()();
  TextColumn get templateId => text()();
  TextColumn get exerciseId => text()();
  IntColumn get position => integer().withDefault(const Constant(0))();
  IntColumn get sets => integer().withDefault(const Constant(3))();
  IntColumn get repMin => integer().withDefault(const Constant(8))();
  IntColumn get repMax => integer().withDefault(const Constant(12))();
  RealColumn get targetRir => real().nullable()();
  TextColumn get progressionModel =>
      text().withDefault(const Constant('double'))();
  IntColumn get supersetGroup => integer().nullable()();
  IntColumn get restSeconds => integer().nullable()();
  TextColumn get notes => text().nullable()();
}

@DataClassName('WorkoutSession')
class Sessions extends Table with SyncedRow {
  TextColumn get userId => text()();
  TextColumn get templateId => text().nullable()();
  TextColumn get name => text().nullable()();
  DateTimeColumn get startedAt => dateTime().clientDefault(nowUtc)();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get readiness => integer().nullable()();
  TextColumn get notes => text().nullable()();
}

class SessionExercises extends Table with SyncedRow {
  TextColumn get userId => text()();
  TextColumn get sessionId => text()();
  TextColumn get exerciseId => text()();
  IntColumn get position => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();
}

@DataClassName('WorkoutSet')
class WorkoutSets extends Table with SyncedRow {
  @override
  String get tableName => 'sets';

  TextColumn get userId => text()();
  TextColumn get sessionExerciseId => text()();
  IntColumn get setIndex => integer()();
  TextColumn get kind => text().withDefault(const Constant('working'))();
  RealColumn get weightKg => real().nullable()();
  IntColumn get reps => integer().nullable()();
  RealColumn get rir => real().nullable()();
  RealColumn get rpe => real().nullable()();
  RealColumn get e1rmKg => real().nullable()();
  BoolColumn get isPr => boolean().withDefault(const Constant(false))();
  DateTimeColumn get loggedAt => dateTime().clientDefault(nowUtc)();
}

/// What the growth engine decided for one exercise. One row per exercise —
/// the engine keeps a verdict, not a history.
class ProgressionStates extends Table with SyncedRow {
  @override
  String get tableName => 'progression_state';

  TextColumn get userId => text()();
  TextColumn get exerciseId => text()();
  TextColumn get model => text().withDefault(const Constant('double'))();
  RealColumn get nextLoadKg => real().nullable()();
  IntColumn get nextReps => integer().nullable()();
  IntColumn get stallCount => integer().withDefault(const Constant(0))();
  RealColumn get bestE1rmKg => real().nullable()();
}

// ---------------------------------------------------------------------------
// Phase 2 — Body & Move
//
// One row per calendar day per user, in every table below. The `*On` columns
// are ISO dates (yyyy-MM-dd) rather than DateTimes: they are days in the
// lifter's timezone, and storing an instant would make "Tuesday" depend on
// where they were standing. See the migration for the reasoning in full.
// ---------------------------------------------------------------------------

/// The scale and the tape measure.
@DataClassName('BodyMetric')
class BodyMetrics extends Table with SyncedRow {
  TextColumn get userId => text()();
  TextColumn get measuredOn => text()();
  RealColumn get weightKg => real().nullable()();
  RealColumn get bodyFatPct => real().nullable()();
  RealColumn get neckCm => real().nullable()();
  RealColumn get shouldersCm => real().nullable()();
  RealColumn get chestCm => real().nullable()();
  RealColumn get waistCm => real().nullable()();
  RealColumn get hipsCm => real().nullable()();
  RealColumn get thighCm => real().nullable()();
  RealColumn get calfCm => real().nullable()();
  RealColumn get armCm => real().nullable()();
  RealColumn get forearmCm => real().nullable()();

  /// 'manual' or 'health'. An import must never overwrite a typed-in value.
  TextColumn get source => text().withDefault(const Constant('manual'))();
  TextColumn get notes => text().nullable()();
}

/// Steps and active energy, as imported from Health Connect.
@DataClassName('DailyActivity')
class DailyActivities extends Table with SyncedRow {
  @override
  String get tableName => 'daily_activity';

  TextColumn get userId => text()();
  TextColumn get activityOn => text()();
  IntColumn get steps => integer().nullable()();
  RealColumn get activeKcal => real().nullable()();
  RealColumn get restingKcal => real().nullable()();
  RealColumn get distanceM => real().nullable()();
  IntColumn get floors => integer().nullable()();
  IntColumn get exerciseMinutes => integer().nullable()();
  TextColumn get source => text().withDefault(const Constant('health'))();
}

/// Last night as the watch measured it, plus the morning check-in.
@DataClassName('RecoveryDay')
class RecoveryDays extends Table with SyncedRow {
  @override
  String get tableName => 'recovery_daily';

  TextColumn get userId => text()();
  TextColumn get recoveredOn => text()();
  IntColumn get sleepMinutes => integer().nullable()();
  RealColumn get hrvMs => real().nullable()();
  RealColumn get restingHr => real().nullable()();

  /// The check-in, 1-5 each. [soreness] and [stress] run the other way round;
  /// packages/engine knows which way each points, and nothing else should.
  IntColumn get sleepQuality => integer().nullable()();
  IntColumn get soreness => integer().nullable()();
  IntColumn get stress => integer().nullable()();
  IntColumn get energy => integer().nullable()();
  DateTimeColumn get checkedInAt => dateTime().nullable()();

  /// What the engine scored the morning at, 0-100.
  IntColumn get readiness => integer().nullable()();
  TextColumn get notes => text().nullable()();
}

/// A progress photo. The row syncs; the image itself lives in the private
/// progress-photos bucket at [storagePath].
@DataClassName('ProgressPhoto')
class ProgressPhotos extends Table with SyncedRow {
  TextColumn get userId => text()();
  TextColumn get takenOn => text()();
  TextColumn get pose => text().withDefault(const Constant('front'))();
  TextColumn get storagePath => text()();
  RealColumn get weightKg => real().nullable()();
  TextColumn get notes => text().nullable()();
}

/// One day with everything already joined — what Today and Progress read.
///
/// Derived: every column here can be recomputed from the tables above and from
/// the training log. It exists so a dashboard is one query, and so the coach
/// sees a day the same way the lifter did.
@DataClassName('DailyRollup')
class DailyRollups extends Table with SyncedRow {
  @override
  String get tableName => 'daily_rollup';

  TextColumn get userId => text()();
  TextColumn get rollupOn => text()();
  RealColumn get trendWeightKg => real().nullable()();
  RealColumn get weightKg => real().nullable()();
  IntColumn get steps => integer().nullable()();
  IntColumn get sleepMinutes => integer().nullable()();
  IntColumn get readiness => integer().nullable()();
  IntColumn get hardSets => integer().nullable()();
  RealColumn get volumeKg => real().nullable()();

  /// Phase 3 fills these in; nothing writes them yet.
  IntColumn get intakeKcal => integer().nullable()();
  RealColumn get proteinG => real().nullable()();
  IntColumn get tdeeEst => integer().nullable()();

  /// Phase 5.
  IntColumn get fatigueScore => integer().nullable()();

  TextColumn get phase => text().nullable()();
}

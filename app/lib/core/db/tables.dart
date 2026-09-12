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

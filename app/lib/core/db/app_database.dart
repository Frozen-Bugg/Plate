import 'package:drift/drift.dart';
// Used by the generated code for SyncedRow's client-side id default.
import 'package:powersync/powersync.dart' show uuid;

import 'tables.dart';

export 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [
  Profiles,
  Exercises,
  Programs,
  Mesocycles,
  Templates,
  TemplateExercises,
  Sessions,
  SessionExercises,
  WorkoutSets,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.connection);

  @override
  int get schemaVersion => 1;

  // PowerSync creates and migrates the underlying tables from
  // powersync_schema.dart, so Drift must never create or alter them.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {},
        onUpgrade: (m, from, to) async {},
      );
}

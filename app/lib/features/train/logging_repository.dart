import 'package:drift/drift.dart';
import 'package:engine/engine.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

/// Exercises inside a session, and the sets logged against them.
///
/// Every write lands in the local database first and syncs when there is a
/// connection — the gym is the one place a phone reliably has none.
class LoggingRepository {
  LoggingRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  Stream<List<SessionExercise>> watchExercises(String sessionId) {
    return (_db.select(_db.sessionExercises)
          ..where((e) => e.sessionId.equals(sessionId))
          ..where((e) => e.deletedAt.isNull())
          ..orderBy([(e) => OrderingTerm.asc(e.position)]))
        .watch();
  }

  Stream<List<WorkoutSet>> watchSets(String sessionExerciseId) {
    return (_db.select(_db.workoutSets)
          ..where((s) => s.sessionExerciseId.equals(sessionExerciseId))
          ..where((s) => s.deletedAt.isNull())
          ..orderBy([(s) => OrderingTerm.asc(s.setIndex)]))
        .watch();
  }

  /// Adds [exerciseId] to the end of the session and returns the new row's id.
  Future<String> addExercise({
    required String sessionId,
    required String exerciseId,
  }) async {
    final existing = await (_db.select(_db.sessionExercises)
          ..where((e) => e.sessionId.equals(sessionId))
          ..where((e) => e.deletedAt.isNull()))
        .get();
    // PowerSync tables are views, so RETURNING does not work: make the id here.
    final id = uuid.v7();
    await _db.into(_db.sessionExercises).insert(
          SessionExercisesCompanion.insert(
            id: Value(id),
            userId: _userId,
            sessionId: sessionId,
            exerciseId: exerciseId,
            position: Value(existing.length),
          ),
        );
    return id;
  }

  Future<void> removeExercise(String sessionExerciseId) =>
      (_db.update(_db.sessionExercises)
            ..where((e) => e.id.equals(sessionExerciseId)))
          .write(
        SessionExercisesCompanion(
          deletedAt: Value(nowUtc()),
          updatedAt: Value(nowUtc()),
        ),
      );

  /// Logs one working set. The estimated one-rep max is computed here rather
  /// than read back later, so history stays comparable even if the formula
  /// changes: the number is what the engine believed at the time.
  /// The best estimated one-rep max ever logged for [exerciseId], across every
  /// session that still counts. Read from the sets themselves rather than from
  /// progression_state, which is only rewritten when a session is finished and
  /// so would miss earlier sets of the session in progress.
  Future<double?> bestE1rmFor(String exerciseId) async {
    final sets = _db.workoutSets;
    final exercises = _db.sessionExercises;
    final best = sets.e1rmKg.max();

    final row = await (_db.selectOnly(sets).join([
      innerJoin(exercises, exercises.id.equalsExp(sets.sessionExerciseId)),
    ])
          ..addColumns([best])
          ..where(exercises.exerciseId.equals(exerciseId) &
              sets.userId.equals(_userId) &
              sets.deletedAt.isNull() &
              exercises.deletedAt.isNull()))
        .getSingleOrNull();

    return row?.read(best);
  }

  Future<String> logSet({
    required String sessionExerciseId,
    required String exerciseId,
    required double weightKg,
    required int reps,
    double? rir,
  }) async {
    final already = await (_db.select(_db.workoutSets)
          ..where((s) => s.sessionExerciseId.equals(sessionExerciseId))
          ..where((s) => s.deletedAt.isNull()))
        .get();

    final e1rm = rir == null
        ? engine.e1rm(loadKg: weightKg, reps: reps)
        : engine.e1rmWithRir(loadKg: weightKg, reps: reps, rir: rir);

    // A personal best is measured in estimated one-rep max, not in load: five
    // reps at 100 beats a single at 105, and a lifter who only ever added
    // weight would never see the sets that actually moved them forward.
    // Strictly greater, so repeating a previous best is not a new one.
    final previousBest = await bestE1rmFor(exerciseId);
    final isPr = previousBest == null || e1rm > previousBest + 1e-9;

    final id = uuid.v7();
    await _db.into(_db.workoutSets).insert(
          WorkoutSetsCompanion.insert(
            id: Value(id),
            userId: _userId,
            sessionExerciseId: sessionExerciseId,
            setIndex: already.length,
            // kind and isPr carry Drift defaults, but PowerSync creates the
            // local tables, so no DEFAULT exists there: an omitted column is
            // written as NULL. Drift then throws mapping NULL into a
            // non-nullable field, and Postgres rejects the upload because both
            // are NOT NULL. Always write them.
            kind: const Value('working'),
            isPr: Value(isPr),
            weightKg: Value(weightKg),
            reps: Value(reps),
            rir: Value(rir),
            rpe: Value(rir == null ? null : engine.rirToRpe(rir)),
            e1rmKg: Value(e1rm),
          ),
        );
    return id;
  }

  Future<void> deleteSet(String setId) =>
      (_db.update(_db.workoutSets)..where((s) => s.id.equals(setId))).write(
        WorkoutSetsCompanion(
          deletedAt: Value(nowUtc()),
          updatedAt: Value(nowUtc()),
        ),
      );
}

final loggingRepositoryProvider = Provider<LoggingRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('LoggingRepository used while signed out');
  }
  return LoggingRepository(ref.watch(appDatabaseProvider), user.id);
});

final sessionExercisesProvider =
    StreamProvider.family<List<SessionExercise>, String>(
  (ref, sessionId) =>
      ref.watch(loggingRepositoryProvider).watchExercises(sessionId),
);

final setsProvider = StreamProvider.family<List<WorkoutSet>, String>(
  (ref, sessionExerciseId) =>
      ref.watch(loggingRepositoryProvider).watchSets(sessionExerciseId),
);

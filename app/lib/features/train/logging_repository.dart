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

  /// Rewrites `position` for every exercise in the session to match
  /// [orderedIds] — see [TemplatesRepository.reorderExercises], same reasoning,
  /// same shape, different table.
  Future<void> reorderExercises(
    String sessionId,
    List<String> orderedIds,
  ) async {
    final now = nowUtc();
    await _db.transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (_db.update(_db.sessionExercises)
              ..where((e) => e.id.equals(orderedIds[i]))
              ..where((e) => e.sessionId.equals(sessionId)))
            .write(
          SessionExercisesCompanion(
            position: Value(i),
            updatedAt: Value(now),
          ),
        );
      }
    });
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

  /// Everything logged in one session: its exercises in order, each with the
  /// sets done against it.
  ///
  /// One joined query rather than one per exercise, and a left join so an
  /// exercise that was set up and then abandoned still appears — that it was
  /// started and dropped is information too.
  Stream<List<LoggedExercise>> watchSession(String sessionId) {
    final query = _db.select(_db.sessionExercises).join([
      leftOuterJoin(
        _db.workoutSets,
        _db.workoutSets.sessionExerciseId.equalsExp(_db.sessionExercises.id) &
            _db.workoutSets.deletedAt.isNull(),
      ),
    ])
      ..where(_db.sessionExercises.sessionId.equals(sessionId) &
          _db.sessionExercises.userId.equals(_userId) &
          _db.sessionExercises.deletedAt.isNull())
      ..orderBy([
        OrderingTerm.asc(_db.sessionExercises.position),
        OrderingTerm.asc(_db.workoutSets.setIndex),
      ]);

    // Watching a join means the stream re-emits when *either* table changes,
    // which is what a screen showing sets inside exercises needs.
    return query.watch().map(_group);
  }

  /// A summary of every session, keyed by session id.
  ///
  /// Summarised in one query rather than one per session: fifty sessions on the
  /// Train screen would otherwise be a hundred round-trips every time a set is
  /// logged.
  Stream<Map<String, SessionSummary>> watchSummaries() {
    final query = _db.select(_db.sessionExercises).join([
      leftOuterJoin(
        _db.workoutSets,
        _db.workoutSets.sessionExerciseId.equalsExp(_db.sessionExercises.id) &
            _db.workoutSets.deletedAt.isNull(),
      ),
    ])
      ..where(_db.sessionExercises.userId.equals(_userId) &
          _db.sessionExercises.deletedAt.isNull())
      ..orderBy([OrderingTerm.asc(_db.sessionExercises.position)]);

    return query.watch().map((rows) {
      final summaries = <String, SessionSummary>{};
      final counted = <String>{};

      for (final row in rows) {
        final exercise = row.readTable(_db.sessionExercises);
        final current = summaries[exercise.sessionId] ?? emptySummary;

        // A left join repeats the exercise once per set, so its id must only
        // be added the first time it is seen.
        final first = counted.add(exercise.id);
        final set = row.readTableOrNull(_db.workoutSets);

        var volume = current.volumeKg;
        if (set != null) {
          if (set.reps case final reps? when reps > 0) {
            volume += (set.weightKg ?? 0) * reps;
          }
        }
        final best = switch ((current.bestE1rmKg, set?.e1rmKg)) {
          (final a?, final b?) => a > b ? a : b,
          (final a?, null) => a,
          (null, final b?) => b,
          _ => null,
        };

        summaries[exercise.sessionId] = (
          exerciseIds: first
              ? [...current.exerciseIds, exercise.exerciseId]
              : current.exerciseIds,
          setCount: current.setCount + (set == null ? 0 : 1),
          volumeKg: volume,
          prCount: current.prCount + (set != null && set.isPr ? 1 : 0),
          bestE1rmKg: best,
        );
      }
      return summaries;
    });
  }

  /// Folds a joined exercise/set result back into nested lists.
  List<LoggedExercise> _group(List<TypedResult> rows) {
    final order = <String>[];
    final exercises = <String, SessionExercise>{};
    final sets = <String, List<WorkoutSet>>{};

    for (final row in rows) {
      final exercise = row.readTable(_db.sessionExercises);
      if (!exercises.containsKey(exercise.id)) {
        exercises[exercise.id] = exercise;
        sets[exercise.id] = [];
        order.add(exercise.id);
      }
      if (row.readTableOrNull(_db.workoutSets) case final set?) {
        sets[exercise.id]!.add(set);
      }
    }

    return [
      for (final id in order) (exercise: exercises[id]!, sets: sets[id]!),
    ];
  }

  /// What was logged for [exerciseId] last time, from the most recent other
  /// session that touched it — Hevy's "previous" column.
  ///
  /// A target from the engine says what *should* happen; this says what
  /// *did*, set by set, which is the number a lifter actually checks their
  /// own effort against mid-session. Excludes [excludingSessionId] so the
  /// session in progress never shows itself back as its own history.
  Future<List<WorkoutSet>> previousSets({
    required String exerciseId,
    required String excludingSessionId,
  }) async {
    final exercises = _db.sessionExercises;
    final sessions = _db.sessions;
    final id = exercises.id;

    final row = await (_db.selectOnly(exercises)
          ..addColumns([id])
          ..join([
            innerJoin(sessions, sessions.id.equalsExp(exercises.sessionId)),
          ])
          ..where(exercises.exerciseId.equals(exerciseId) &
              exercises.userId.equals(_userId) &
              exercises.deletedAt.isNull() &
              exercises.sessionId.equals(excludingSessionId).not() &
              sessions.deletedAt.isNull())
          ..orderBy([OrderingTerm.desc(sessions.startedAt)])
          ..limit(1))
        .getSingleOrNull();

    final previousSessionExerciseId = row?.read(id);
    if (previousSessionExerciseId == null) return const [];

    return (_db.select(_db.workoutSets)
          ..where((s) => s.sessionExerciseId.equals(previousSessionExerciseId))
          ..where((s) => s.deletedAt.isNull())
          ..orderBy([(s) => OrderingTerm.asc(s.setIndex)]))
        .get();
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

/// Keys [previousSetsProvider] by exercise and the session to exclude. A
/// record rather than two params: Riverpod families need one Object, and
/// Dart records compare structurally, so this works as a family key for free.
typedef PreviousSetsKey = ({String exerciseId, String sessionId});

final previousSetsProvider =
    FutureProvider.family<List<WorkoutSet>, PreviousSetsKey>(
  (ref, key) => ref.watch(loggingRepositoryProvider).previousSets(
        exerciseId: key.exerciseId,
        excludingSessionId: key.sessionId,
      ),
);

/// What a finished session amounted to.
///
/// History used to show only that a workout happened, and for how long. "Sat 12
/// Sep, 52 min" is a receipt, not a training log: it cannot answer what was
/// trained, how heavy, or whether it beat last week — which is the entire
/// reason for keeping one.
typedef SessionSummary = ({
  List<String> exerciseIds,
  int setCount,
  double volumeKg,
  int prCount,
  double? bestE1rmKg,
});

const emptySummary = (
  exerciseIds: <String>[],
  setCount: 0,
  volumeKg: 0.0,
  prCount: 0,
  bestE1rmKg: null,
);

/// One session's exercises with their sets, in the order they were trained.
typedef LoggedExercise = ({SessionExercise exercise, List<WorkoutSet> sets});

/// One row per session, for the whole history list.
final sessionSummariesProvider =
    StreamProvider<Map<String, SessionSummary>>((ref) {
  return ref.watch(loggingRepositoryProvider).watchSummaries();
});

/// One session in full, for the detail screen.
final sessionDetailProvider =
    StreamProvider.family<List<LoggedExercise>, String>(
  (ref, sessionId) =>
      ref.watch(loggingRepositoryProvider).watchSession(sessionId),
);

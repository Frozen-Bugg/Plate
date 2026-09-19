import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

/// Workout sessions for the signed-in user. Every write goes to the local
/// database first and syncs when a connection is available.
class SessionsRepository {
  SessionsRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  Stream<List<WorkoutSession>> watchRecent({int limit = 50}) {
    return (_db.select(_db.sessions)
          ..where((s) => s.userId.equals(_userId) & s.deletedAt.isNull())
          ..orderBy([(s) => OrderingTerm.desc(s.startedAt)])
          ..limit(limit))
        .watch();
  }

  /// The session that has been started but not finished, if any. There should
  /// never be more than one; the oldest wins so a stray extra cannot hide the
  /// real one.
  Future<WorkoutSession?> activeSession() async {
    final open =
        await (_db.select(_db.sessions)
              ..where((s) => s.userId.equals(_userId))
              ..where((s) => s.deletedAt.isNull())
              ..where((s) => s.endedAt.isNull())
              ..orderBy([(s) => OrderingTerm.asc(s.startedAt)])
              ..limit(1))
            .get();
    return open.firstOrNull;
  }

  /// Starts a session now and returns its id. [templateId] records which plan
  /// it came from, when it came from one at all.
  ///
  /// Throws if one is already running: two open sessions orphan the earlier
  /// one, which then cannot be finished or discarded from anywhere.
  Future<String> start({String? templateId}) async {
    if (await activeSession() case final running?) {
      throw StateError('A workout is already running (${running.id})');
    }
    // PowerSync tables are views, which don't support RETURNING, so the id is
    // generated here rather than read back.
    final id = uuid.v7();
    await _db
        .into(_db.sessions)
        .insert(
          SessionsCompanion.insert(
            id: Value(id),
            userId: _userId,
            templateId: Value(templateId),
          ),
        );
    return id;
  }

  Future<void> finish(String id) =>
      _update(id, SessionsCompanion(endedAt: Value(nowUtc())));

  /// Writes a session that already happened — imported history rather than
  /// something being trained right now. Bypasses the one-running-session rule
  /// [start] enforces, since a row created here never has a null `endedAt`
  /// and so never counts as active.
  Future<String> createFinished({
    required DateTime startedAt,
    required DateTime endedAt,
    String? name,
  }) async {
    final id = uuid.v7();
    await _db
        .into(_db.sessions)
        .insert(
          SessionsCompanion.insert(
            id: Value(id),
            userId: _userId,
            name: Value(name),
            startedAt: Value(startedAt),
            endedAt: Value(endedAt),
          ),
        );
    return id;
  }

  /// Soft delete, so the deletion reaches every device.
  ///
  /// Cascades by hand. Postgres cascades the composite foreign key on a *hard*
  /// delete, but this is a soft one: without marking the children too, the
  /// exercises and sets stay in the database forever, invisible to every
  /// screen and still syncing to every device.
  ///
  /// Returns the exercises that were trained, so the caller can ask the engine
  /// to reconsider — its verdict was based on sets that no longer count.
  Future<Set<String>> delete(String id) async {
    final now = nowUtc();

    final trained = await (_db.select(
      _db.sessionExercises,
    )..where((e) => e.sessionId.equals(id))).get();

    for (final exercise in trained) {
      await (_db.update(_db.workoutSets)
            ..where((s) => s.sessionExerciseId.equals(exercise.id))
            ..where((s) => s.deletedAt.isNull()))
          .write(
            WorkoutSetsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
          );
    }

    await (_db.update(_db.sessionExercises)
          ..where((e) => e.sessionId.equals(id))
          ..where((e) => e.deletedAt.isNull()))
        .write(
          SessionExercisesCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );

    await _update(id, SessionsCompanion(deletedAt: Value(now)));
    return trained.map((e) => e.exerciseId).toSet();
  }

  Future<void> _update(String id, SessionsCompanion changes) {
    return (_db.update(_db.sessions)..where((s) => s.id.equals(id))).write(
      changes.copyWith(updatedAt: Value(nowUtc())),
    );
  }
}

final sessionsRepositoryProvider = Provider<SessionsRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('SessionsRepository used while signed out');
  }
  return SessionsRepository(ref.watch(appDatabaseProvider), user.id);
});

final recentSessionsProvider = StreamProvider<List<WorkoutSession>>(
  (ref) => ref.watch(sessionsRepositoryProvider).watchRecent(),
);

/// The session that has been started but not finished, if any.
///
/// recentSessionsProvider is newest first, so this takes the last match: the
/// oldest unfinished session. If an extra one ever gets created, the original
/// still surfaces and can be finished or discarded rather than stranded.
final activeSessionProvider = Provider<WorkoutSession?>((ref) {
  final sessions = ref.watch(recentSessionsProvider).value ?? const [];
  return sessions.where((s) => s.endedAt == null).lastOrNull;
});

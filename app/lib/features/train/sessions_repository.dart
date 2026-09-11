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

  /// Starts a session now and returns its id.
  Future<String> start() async {
    // PowerSync tables are views, which don't support RETURNING, so the id is
    // generated here rather than read back.
    final id = uuid.v7();
    await _db
        .into(_db.sessions)
        .insert(SessionsCompanion.insert(id: Value(id), userId: _userId));
    return id;
  }

  Future<void> finish(String id) =>
      _update(id, SessionsCompanion(endedAt: Value(nowUtc())));

  /// Soft delete, so the deletion reaches every device.
  Future<void> delete(String id) =>
      _update(id, SessionsCompanion(deletedAt: Value(nowUtc())));

  Future<void> _update(String id, SessionsCompanion changes) {
    return (_db.update(_db.sessions)..where((s) => s.id.equals(id)))
        .write(changes.copyWith(updatedAt: Value(nowUtc())));
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
final activeSessionProvider = Provider<WorkoutSession?>((ref) {
  final sessions = ref.watch(recentSessionsProvider).value ?? const [];
  return sessions.where((s) => s.endedAt == null).firstOrNull;
});

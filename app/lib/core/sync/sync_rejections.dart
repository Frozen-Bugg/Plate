import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_database.dart';
import '../db/database_providers.dart';

/// Writes Postgres refused, which PowerSync then dropped from the queue.
///
/// The drop is deliberate — a write that can never succeed would otherwise
/// block every later one behind it — but it leaves the device holding a row the
/// server has never seen, and nothing about that is visible from the outside.
/// This is the record that makes it visible.
///
/// Local only: the write never reached the server, so there is nowhere to sync
/// a record of it to.
class SyncRejectionsRepository {
  SyncRejectionsRepository(this._db);

  final AppDatabase _db;

  /// Everything still unacknowledged, newest first.
  Stream<List<SyncRejection>> watchOutstanding() {
    return (_db.select(_db.syncRejections)
          ..where((r) => r.acknowledged.equals(false))
          ..orderBy([(r) => OrderingTerm.desc(r.occurredAt)]))
        .watch();
  }

  /// Marks them seen. This does not recover the write — nothing can, from here
  /// — it only stops the app reporting a loss the lifter has already read.
  Future<void> acknowledgeAll() =>
      (_db.update(_db.syncRejections)
            ..where((r) => r.acknowledged.equals(false)))
          .write(const SyncRejectionsCompanion(acknowledged: Value(true)));
}

final syncRejectionsRepositoryProvider = Provider<SyncRejectionsRepository>(
  (ref) => SyncRejectionsRepository(ref.watch(appDatabaseProvider)),
);

final outstandingRejectionsProvider = StreamProvider<List<SyncRejection>>(
  (ref) => ref.watch(syncRejectionsRepositoryProvider).watchOutstanding(),
);

/// Plain English for a SQLSTATE, because "23514" tells a lifter nothing.
///
/// Every one of these is a bug in the app rather than anything the user did,
/// so the wording says what was lost and stops short of blaming them for it.
String describeRejection(SyncRejection rejection) => switch (rejection.code) {
      '23505' => 'A record for that already existed on the server.',
      '23503' => 'It referred to something the server does not have.',
      '23502' => 'A required field was empty.',
      '23514' => 'A value was outside the range the server allows.',
      '42501' => 'The server would not let this account write it.',
      final code when code.startsWith('22') => 'A value had the wrong type.',
      _ => 'The server refused it.',
    };

/// "3 sets and 1 weigh-in", for a summary line.
String summariseRejections(List<SyncRejection> rejections) {
  final counts = <String, int>{};
  for (final rejection in rejections) {
    counts.update(rejection.rejectedTable, (n) => n + 1, ifAbsent: () => 1);
  }
  final parts = [
    for (final MapEntry(:key, :value) in counts.entries)
      '$value ${_readableTable(key, plural: value != 1)}',
  ]..sort();

  return switch (parts.length) {
    0 => 'nothing',
    1 => parts.single,
    _ => '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}',
  };
}

String _readableTable(String table, {required bool plural}) {
  final (single, many) = switch (table) {
    'sets' => ('set', 'sets'),
    'sessions' => ('workout', 'workouts'),
    'session_exercises' => ('exercise', 'exercises'),
    'templates' => ('template', 'templates'),
    'template_exercises' => ('template exercise', 'template exercises'),
    'body_metrics' => ('weigh-in', 'weigh-ins'),
    'recovery_daily' => ('check-in', 'check-ins'),
    'daily_activity' => ('activity day', 'activity days'),
    'daily_rollup' => ('daily summary', 'daily summaries'),
    'progress_photos' => ('photo', 'photos'),
    'progression_state' => ('target', 'targets'),
    'profiles' => ('profile change', 'profile changes'),
    'exercises' => ('exercise', 'exercises'),
    _ => (table, table),
  };
  return plural ? many : single;
}

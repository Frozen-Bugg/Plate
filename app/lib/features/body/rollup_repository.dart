import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';
import 'activity_repository.dart';
import 'body_repository.dart';
import 'recovery_repository.dart';

/// What a day amounted to in the gym.
typedef TrainingDay = ({int hardSets, double volumeKg});

/// One row per day with the whole day already joined: what was lifted, what the
/// scale said, how many steps, how the morning felt.
///
/// Every column is derived — delete the table and it rebuilds from the logs. It
/// exists because a dashboard, a weekly review and the coach's context window
/// all want "the last thirty days" as one query rather than five, and because
/// the coach should see the day as the lifter saw it rather than recomputing it
/// against whatever the rules happen to say later.
///
/// Being derived, it is always rewritten and never accumulated.
class RollupRepository {
  RollupRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  Stream<List<DailyRollup>> watchRecent({int days = 90}) {
    final from = daysAgo(days);
    return (_db.select(_db.dailyRollups)
          ..where((r) => r.userId.equals(_userId))
          ..where((r) => r.deletedAt.isNull())
          ..where((r) => r.rollupOn.isBiggerOrEqualValue(from))
          ..orderBy([(r) => OrderingTerm.asc(r.rollupOn)]))
        .watch();
  }

  /// Rebuilds the last [days] from the tables they are derived from.
  ///
  /// A batch on purpose. Recomputing one day at a time would re-read every
  /// session and every set once per day in the window; this reads each source
  /// once and buckets in memory. A fortnight is the default because that is how
  /// far back a late Health import or a corrected weigh-in realistically
  /// reaches.
  ///
  /// [trendByDay] comes from the caller: the trend is a property of the whole
  /// series rather than of one day, and the engine owns that arithmetic.
  Future<void> recomputeRecent({
    int days = 14,
    Map<String, double> trendByDay = const {},
  }) async {
    final from = daysAgo(days - 1);
    final training = await _trainingByDay(from);

    final body = {
      for (final row in await _rowsSince(_db.bodyMetrics, from)) row.measuredOn: row,
    };
    final activity = {
      for (final row in await _activitySince(from)) row.activityOn: row,
    };
    final recovery = {
      for (final row in await _recoverySince(from)) row.recoveredOn: row,
    };
    final existing = {
      for (final row in await _rollupsSince(from)) row.rollupOn: row,
    };

    final profile = await (_db.select(_db.profiles)
          ..where((p) => p.id.equals(_userId))
          ..limit(1))
        .getSingleOrNull();

    for (var i = 0; i < days; i++) {
      final day = daysAgo(i);
      await _write(
        day: day,
        existing: existing[day],
        training: training[day],
        body: body[day],
        activity: activity[day],
        recovery: recovery[day],
        phase: profile?.phase,
        trendWeightKg: trendByDay[day],
      );
    }
  }

  Future<void> _write({
    required String day,
    required DailyRollup? existing,
    required TrainingDay? training,
    required BodyMetric? body,
    required DailyActivity? activity,
    required RecoveryDay? recovery,
    required String? phase,
    required double? trendWeightKg,
  }) async {
    final changes = DailyRollupsCompanion(
      trendWeightKg: Value(trendWeightKg),
      weightKg: Value(body?.weightKg),
      steps: Value(activity?.steps),
      sleepMinutes: Value(recovery?.sleepMinutes),
      readiness: Value(recovery?.readiness),
      hardSets: Value(training?.hardSets),
      volumeKg: Value(training?.volumeKg),
      phase: Value(phase),
    );

    if (existing != null) {
      // Only write when something actually moved: this runs on every change to
      // any source table, and a no-op update would still bump updated_at and
      // push a row through sync for nothing.
      final same = existing.trendWeightKg == trendWeightKg &&
          existing.weightKg == body?.weightKg &&
          existing.steps == activity?.steps &&
          existing.sleepMinutes == recovery?.sleepMinutes &&
          existing.readiness == recovery?.readiness &&
          existing.hardSets == training?.hardSets &&
          existing.volumeKg == training?.volumeKg &&
          existing.phase == phase;
      if (same) return;

      await (_db.update(_db.dailyRollups)..where((r) => r.id.equals(existing.id)))
          .write(changes.copyWith(updatedAt: Value(nowUtc())));
      return;
    }

    // Nothing happened and nothing is stored: do not write an empty row. A
    // rollup for every rest day would be mostly nulls and would make "days
    // logged" meaningless.
    if (training == null && body == null && activity == null && recovery == null) {
      return;
    }

    // Views do not support RETURNING, so the id is generated here.
    await _db.into(_db.dailyRollups).insert(
          DailyRollupsCompanion.insert(
            id: Value(uuid.v7()),
            userId: _userId,
            rollupOn: day,
          ).copyWith(
            trendWeightKg: changes.trendWeightKg,
            weightKg: changes.weightKg,
            steps: changes.steps,
            sleepMinutes: changes.sleepMinutes,
            readiness: changes.readiness,
            hardSets: changes.hardSets,
            volumeKg: changes.volumeKg,
            phase: changes.phase,
          ),
        );
  }

  /// What was lifted on each day since [from], in one pass.
  ///
  /// A hard set is a working set that was actually performed — warm-ups say
  /// nothing about how much work a day was, which is the number a deload
  /// decision (Phase 5) will hang off. Volume is load times reps: the crudest
  /// useful measure, and the one every lifter already knows.
  Future<Map<String, TrainingDay>> _trainingByDay(String from) async {
    final sessions = await (_db.select(_db.sessions)
          ..where((s) => s.userId.equals(_userId))
          ..where((s) => s.deletedAt.isNull()))
        .get();
    // startedAt is a UTC instant and the key is a local day, so the window is
    // filtered here rather than in SQL.
    final inWindow = {
      for (final s in sessions)
        if (dayKey(s.startedAt).compareTo(from) >= 0) s.id: dayKey(s.startedAt),
    };
    if (inWindow.isEmpty) return const {};

    final exercises = await (_db.select(_db.sessionExercises)
          ..where((e) => e.userId.equals(_userId))
          ..where((e) => e.deletedAt.isNull())
          ..where((e) => e.sessionId.isIn(inWindow.keys)))
        .get();
    final dayOfExercise = {
      for (final e in exercises) e.id: ?inWindow[e.sessionId],
    };
    if (dayOfExercise.isEmpty) return const {};

    final sets = await (_db.select(_db.workoutSets)
          ..where((s) => s.userId.equals(_userId))
          ..where((s) => s.deletedAt.isNull())
          ..where((s) => s.sessionExerciseId.isIn(dayOfExercise.keys))
          // Rows written before `kind` was set explicitly have none, and they
          // were all working sets.
          ..where((s) => s.kind.equals('working') | s.kind.isNull()))
        .get();

    final byDay = <String, TrainingDay>{};
    for (final set in sets) {
      final day = dayOfExercise[set.sessionExerciseId];
      if (day == null) continue;
      if (set.reps case final reps? when reps > 0) {
        final current = byDay[day] ?? (hardSets: 0, volumeKg: 0.0);
        byDay[day] = (
          hardSets: current.hardSets + 1,
          volumeKg: current.volumeKg + (set.weightKg ?? 0) * reps,
        );
      }
    }
    return byDay;
  }

  Future<List<BodyMetric>> _rowsSince(TableInfo<BodyMetrics, BodyMetric> table,
          String from) =>
      (_db.select(table)
            ..where((b) => b.userId.equals(_userId))
            ..where((b) => b.deletedAt.isNull())
            ..where((b) => b.measuredOn.isBiggerOrEqualValue(from)))
          .get();

  Future<List<DailyActivity>> _activitySince(String from) =>
      (_db.select(_db.dailyActivities)
            ..where((a) => a.userId.equals(_userId))
            ..where((a) => a.deletedAt.isNull())
            ..where((a) => a.activityOn.isBiggerOrEqualValue(from)))
          .get();

  Future<List<RecoveryDay>> _recoverySince(String from) =>
      (_db.select(_db.recoveryDays)
            ..where((r) => r.userId.equals(_userId))
            ..where((r) => r.deletedAt.isNull())
            ..where((r) => r.recoveredOn.isBiggerOrEqualValue(from)))
          .get();

  Future<List<DailyRollup>> _rollupsSince(String from) =>
      (_db.select(_db.dailyRollups)
            ..where((r) => r.userId.equals(_userId))
            ..where((r) => r.deletedAt.isNull())
            ..where((r) => r.rollupOn.isBiggerOrEqualValue(from)))
          .get();
}

final rollupRepositoryProvider = Provider<RollupRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('RollupRepository used while signed out');
  }
  return RollupRepository(ref.watch(appDatabaseProvider), user.id);
});

final dailyRollupsProvider = StreamProvider<List<DailyRollup>>(
  (ref) => ref.watch(rollupRepositoryProvider).watchRecent(),
);

/// Keeps the recent rollups in step with the tables they are derived from.
///
/// Watching rather than scheduling: the moment a weigh-in, a check-in, an
/// import or a logged set lands, this recomputes the fortnight around it. A
/// derived table refreshed on a timer is a derived table that is wrong for a
/// while, and "wrong for a while" is how a dashboard loses trust.
///
/// Recomputing writes nothing when nothing changed, so the common case — a
/// rebuild triggered by an unrelated stream — costs a few reads and no sync
/// traffic.
final rollupKeeperProvider = Provider<void>((ref) {
  final trend = ref.watch(weightTrendProvider);
  ref.watch(recentActivityProvider);
  ref.watch(recentRecoveryProvider);

  final repository = ref.read(rollupRepositoryProvider);
  repository.recomputeRecent(
    trendByDay: {for (final point in trend) dayKey(point.date): point.trendKg},
  );
});

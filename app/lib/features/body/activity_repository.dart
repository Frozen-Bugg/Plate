import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

/// Steps and active energy, one row per day.
///
/// Written by the Health import rather than by hand in the normal case: the
/// phone already counts steps, and asking a lifter to type them in would be a
/// worse number and a worse app.
class ActivityRepository {
  ActivityRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  Stream<List<DailyActivity>> watchRecent({int days = 90}) {
    final from = daysAgo(days);
    return (_db.select(_db.dailyActivities)
          ..where((a) => a.userId.equals(_userId))
          ..where((a) => a.deletedAt.isNull())
          ..where((a) => a.activityOn.isBiggerOrEqualValue(from))
          ..orderBy([(a) => OrderingTerm.asc(a.activityOn)]))
        .watch();
  }

  Future<DailyActivity?> forDay(String day) =>
      (_db.select(_db.dailyActivities)
            ..where((a) => a.userId.equals(_userId))
            ..where((a) => a.deletedAt.isNull())
            ..where((a) => a.activityOn.equals(day))
            ..limit(1))
          .getSingleOrNull();

  /// Records a day's movement, merging into whatever is already there.
  ///
  /// Health imports re-read the last several days, because steps keep arriving
  /// after midnight and a watch that was charging catches up later. So this
  /// overwrites rather than accumulates: the newest read of a day wins.
  Future<void> save({
    String? day,
    int? steps,
    double? activeKcal,
    double? restingKcal,
    double? distanceM,
    int? floors,
    int? exerciseMinutes,
    String source = 'health',
  }) async {
    final on = day ?? dayKey();
    final changes = DailyActivitiesCompanion(
      steps: Value.absentIfNull(steps),
      activeKcal: Value.absentIfNull(activeKcal),
      restingKcal: Value.absentIfNull(restingKcal),
      distanceM: Value.absentIfNull(distanceM),
      floors: Value.absentIfNull(floors),
      exerciseMinutes: Value.absentIfNull(exerciseMinutes),
      source: Value(source),
    );

    final existing = await forDay(on);
    if (existing != null) {
      await (_db.update(_db.dailyActivities)
            ..where((a) => a.id.equals(existing.id)))
          .write(changes.copyWith(updatedAt: Value(nowUtc())));
      return;
    }
    // Views do not support RETURNING, so the id is generated here, and every
    // non-nullable column is written explicitly (see CLAUDE.md).
    await _db.into(_db.dailyActivities).insert(
          DailyActivitiesCompanion.insert(
            id: Value(dayRowId(
              userId: _userId,
              table: 'daily_activity',
              day: on,
            )),
            userId: _userId,
            activityOn: on,
            source: Value(source),
          ).copyWith(
            steps: changes.steps,
            activeKcal: changes.activeKcal,
            restingKcal: changes.restingKcal,
            distanceM: changes.distanceM,
            floors: changes.floors,
            exerciseMinutes: changes.exerciseMinutes,
          ),
        );
  }
}

final activityRepositoryProvider = Provider<ActivityRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('ActivityRepository used while signed out');
  }
  return ActivityRepository(ref.watch(appDatabaseProvider), user.id);
});

final recentActivityProvider = StreamProvider<List<DailyActivity>>(
  (ref) => ref.watch(activityRepositoryProvider).watchRecent(),
);

/// Today's steps, once anything has reported them.
final todayStepsProvider = Provider<int?>((ref) {
  final days = ref.watch(recentActivityProvider).value ?? const [];
  final today = dayKey();
  return days.where((d) => d.activityOn == today).firstOrNull?.steps;
});

/// The average daily step count over the last [days] that reported any.
///
/// Days with no data are skipped, not counted as zero: a phone left at home is
/// missing evidence, and averaging it in would drag the number down and, in
/// Phase 3, quietly lower the TDEE estimate built on it.
final stepAverageProvider = Provider.family<int?, int>((ref, days) {
  final recent = ref.watch(recentActivityProvider).value ?? const [];
  final from = daysAgo(days);
  final counts = [
    for (final d in recent)
      if (d.activityOn.compareTo(from) >= 0 && d.steps != null) d.steps!,
  ];
  if (counts.isEmpty) return null;
  return (counts.reduce((a, b) => a + b) / counts.length).round();
});

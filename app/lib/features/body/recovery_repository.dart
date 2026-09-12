import 'package:drift/drift.dart';
import 'package:engine/engine.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

/// Last night and this morning: what a watch measured, what the lifter said,
/// and what the engine made of the two together.
///
/// Readiness is stored rather than computed on read. The coach should see the
/// number the lifter actually saw that morning, and a later change to the
/// formula should not quietly rewrite history.
class RecoveryRepository {
  RecoveryRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  /// How far back the personal baseline for HRV and resting heart rate is
  /// taken from. Long enough to be stable, short enough to follow real change.
  static const baselineDays = 60;

  Stream<List<RecoveryDay>> watchRecent({int days = baselineDays}) {
    final from = daysAgo(days);
    return (_db.select(_db.recoveryDays)
          ..where((r) => r.userId.equals(_userId))
          ..where((r) => r.deletedAt.isNull())
          ..where((r) => r.recoveredOn.isBiggerOrEqualValue(from))
          ..orderBy([(r) => OrderingTerm.asc(r.recoveredOn)]))
        .watch();
  }

  Future<RecoveryDay?> forDay(String day) =>
      (_db.select(_db.recoveryDays)
            ..where((r) => r.userId.equals(_userId))
            ..where((r) => r.deletedAt.isNull())
            ..where((r) => r.recoveredOn.equals(day))
            ..limit(1))
          .getSingleOrNull();

  /// Saves the morning check-in and rescores the day.
  ///
  /// Every answer is optional — a lifter who only wants to say they feel wrecked
  /// can tap one thing and leave.
  Future<void> saveCheckIn({
    int? sleepQuality,
    int? soreness,
    int? stress,
    int? energy,
    String? day,
  }) async {
    final on = day ?? dayKey();
    await _write(
      on,
      RecoveryDaysCompanion(
        sleepQuality: Value(sleepQuality),
        soreness: Value(soreness),
        stress: Value(stress),
        energy: Value(energy),
        checkedInAt: Value(nowUtc()),
      ),
    );
  }

  /// Stores what a wearable reported for [day] and rescores it.
  ///
  /// Used by the Health import. It never touches the check-in answers, so an
  /// import arriving after breakfast cannot overwrite what the lifter said.
  Future<void> saveSignals({
    int? sleepMinutes,
    double? hrvMs,
    double? restingHr,
    String? day,
  }) async {
    final on = day ?? dayKey();
    await _write(
      on,
      RecoveryDaysCompanion(
        sleepMinutes: Value(sleepMinutes),
        hrvMs: Value(hrvMs),
        restingHr: Value(restingHr),
      ),
    );
  }

  /// Soft delete, so the deletion reaches every device.
  Future<void> deleteDay(String day) async {
    final now = nowUtc();
    await (_db.update(_db.recoveryDays)
          ..where((r) => r.userId.equals(_userId))
          ..where((r) => r.recoveredOn.equals(day))
          ..where((r) => r.deletedAt.isNull()))
        .write(
      RecoveryDaysCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  /// What normal looks like for this lifter, from the last [baselineDays].
  ///
  /// HRV and resting heart rate mean nothing in absolute terms — 45 ms is a
  /// good night for one person and a bad one for another — so the engine needs
  /// this before it can score either.
  Future<engine.RecoveryBaseline> baseline() async {
    final rows = await (_db.select(_db.recoveryDays)
          ..where((r) => r.userId.equals(_userId))
          ..where((r) => r.deletedAt.isNull())
          ..where((r) => r.recoveredOn.isBiggerOrEqualValue(daysAgo(baselineDays))))
        .get();
    return engine.recoveryBaseline([
      for (final r in rows)
        engine.RecoverySignals(
          sleepMinutes: r.sleepMinutes,
          hrvMs: r.hrvMs,
          restingHr: r.restingHr,
        ),
    ]);
  }

  /// Merges [changes] into the day's row and rescores readiness from whatever
  /// the row holds afterwards.
  Future<void> _write(String day, RecoveryDaysCompanion changes) async {
    final existing = await forDay(day);
    final merged = _merge(existing, changes);
    final readiness = engine.readinessScore(
      checkIn: engine.CheckIn(
        sleepQuality: merged.sleepQuality,
        soreness: merged.soreness,
        stress: merged.stress,
        energy: merged.energy,
      ),
      signals: engine.RecoverySignals(
        sleepMinutes: merged.sleepMinutes,
        hrvMs: merged.hrvMs,
        restingHr: merged.restingHr,
      ),
      baseline: await baseline(),
    );
    final scored = changes.copyWith(readiness: Value(readiness));

    if (existing != null) {
      await (_db.update(_db.recoveryDays)
            ..where((r) => r.id.equals(existing.id)))
          .write(scored.copyWith(updatedAt: Value(nowUtc())));
      return;
    }
    // Views do not support RETURNING, so the id is generated here.
    await _db.into(_db.recoveryDays).insert(
          RecoveryDaysCompanion.insert(
            id: Value(uuid.v7()),
            userId: _userId,
            recoveredOn: day,
          ).copyWith(
            sleepMinutes: scored.sleepMinutes,
            hrvMs: scored.hrvMs,
            restingHr: scored.restingHr,
            sleepQuality: scored.sleepQuality,
            soreness: scored.soreness,
            stress: scored.stress,
            energy: scored.energy,
            checkedInAt: scored.checkedInAt,
            readiness: scored.readiness,
            notes: scored.notes,
          ),
        );
  }

  /// The day as it will be once [changes] are applied — what readiness has to
  /// be scored from. A field the caller did not set keeps the stored value; a
  /// field set to null clears it.
  _Merged _merge(RecoveryDay? existing, RecoveryDaysCompanion changes) {
    T? pick<T>(Value<T?> change, T? stored) =>
        change.present ? change.value : stored;
    return _Merged(
      sleepMinutes: pick(changes.sleepMinutes, existing?.sleepMinutes),
      hrvMs: pick(changes.hrvMs, existing?.hrvMs),
      restingHr: pick(changes.restingHr, existing?.restingHr),
      sleepQuality: pick(changes.sleepQuality, existing?.sleepQuality),
      soreness: pick(changes.soreness, existing?.soreness),
      stress: pick(changes.stress, existing?.stress),
      energy: pick(changes.energy, existing?.energy),
    );
  }
}

class _Merged {
  const _Merged({
    this.sleepMinutes,
    this.hrvMs,
    this.restingHr,
    this.sleepQuality,
    this.soreness,
    this.stress,
    this.energy,
  });

  final int? sleepMinutes;
  final double? hrvMs;
  final double? restingHr;
  final int? sleepQuality;
  final int? soreness;
  final int? stress;
  final int? energy;
}

final recoveryRepositoryProvider = Provider<RecoveryRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('RecoveryRepository used while signed out');
  }
  return RecoveryRepository(ref.watch(appDatabaseProvider), user.id);
});

final recentRecoveryProvider = StreamProvider<List<RecoveryDay>>(
  (ref) => ref.watch(recoveryRepositoryProvider).watchRecent(),
);

/// This morning's row, if there is one yet.
final todayRecoveryProvider = Provider<RecoveryDay?>((ref) {
  final days = ref.watch(recentRecoveryProvider).value ?? const [];
  final today = dayKey();
  return days.where((d) => d.recoveredOn == today).firstOrNull;
});

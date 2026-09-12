import 'package:drift/drift.dart';
import 'package:engine/engine.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

/// The scale and the tape measure.
///
/// One row per calendar day, so logging twice in a morning corrects the day
/// rather than adding to it. The engine does the smoothing; this class only
/// stores what was measured and hands it over.
class BodyRepository {
  BodyRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  /// Every day with a measurement, oldest first — the order the engine reads.
  ///
  /// [days] bounds the history the trend is built from. A year is far more
  /// than the smoothing can still feel and cheap to carry.
  Stream<List<BodyMetric>> watchRecent({int days = 365}) {
    final from = daysAgo(days);
    return (_db.select(_db.bodyMetrics)
          ..where((b) => b.userId.equals(_userId))
          ..where((b) => b.deletedAt.isNull())
          ..where((b) => b.measuredOn.isBiggerOrEqualValue(from))
          ..orderBy([(b) => OrderingTerm.asc(b.measuredOn)]))
        .watch();
  }

  Future<BodyMetric?> forDay(String day) =>
      (_db.select(_db.bodyMetrics)
            ..where((b) => b.userId.equals(_userId))
            ..where((b) => b.deletedAt.isNull())
            ..where((b) => b.measuredOn.equals(day))
            ..limit(1))
          .getSingleOrNull();

  /// The most recent day carrying a weight, if there is one.
  Future<BodyMetric?> lastWeighIn() async {
    final rows = await (_db.select(_db.bodyMetrics)
          ..where((b) => b.userId.equals(_userId))
          ..where((b) => b.deletedAt.isNull())
          ..where((b) => b.weightKg.isNotNull())
          ..orderBy([(b) => OrderingTerm.desc(b.measuredOn)])
          ..limit(1))
        .get();
    return rows.firstOrNull;
  }

  /// Records a weigh-in for [day], defaulting to today.
  ///
  /// [source] is 'manual' when the lifter typed it. An importer must pass
  /// 'health' and must not call this for a day that already has a manual
  /// reading — a number someone took the trouble to type beats one a scale
  /// synced at some point during the night.
  Future<void> logWeight(
    double kg, {
    String? day,
    String source = 'manual',
  }) async {
    final on = day ?? dayKey();
    final existing = await forDay(on);
    if (existing != null && source == 'health' && existing.source == 'manual') {
      return;
    }
    await _upsert(
      on,
      BodyMetricsCompanion(weightKg: Value(kg), source: Value(source)),
      existing: existing,
    );
  }

  /// Records tape measurements for [day], leaving untouched anything the
  /// caller did not pass. Passing `Value(null)` clears one.
  Future<void> saveMeasurements(
    BodyMetricsCompanion measurements, {
    String? day,
  }) async {
    final on = day ?? dayKey();
    await _upsert(on, measurements, existing: await forDay(on));
  }

  /// Soft delete, so the deletion reaches every device.
  Future<void> deleteDay(String day) async {
    final now = nowUtc();
    await (_db.update(_db.bodyMetrics)
          ..where((b) => b.userId.equals(_userId))
          ..where((b) => b.measuredOn.equals(day))
          ..where((b) => b.deletedAt.isNull()))
        .write(
      BodyMetricsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  Future<void> _upsert(
    String day,
    BodyMetricsCompanion changes, {
    required BodyMetric? existing,
  }) async {
    if (existing != null) {
      await (_db.update(_db.bodyMetrics)
            ..where((b) => b.id.equals(existing.id)))
          .write(changes.copyWith(updatedAt: Value(nowUtc())));
      return;
    }
    // Views do not support RETURNING, so the id is generated here. Every
    // non-nullable column is written explicitly: PowerSync creates the local
    // tables without DEFAULT clauses, so anything left out lands as NULL and
    // Drift throws reading it back (see CLAUDE.md).
    await _db.into(_db.bodyMetrics).insert(
          BodyMetricsCompanion.insert(
            id: Value(uuid.v7()),
            userId: _userId,
            measuredOn: day,
            source: changes.source.present
                ? changes.source
                : const Value('manual'),
          ).copyWith(
            weightKg: changes.weightKg,
            bodyFatPct: changes.bodyFatPct,
            neckCm: changes.neckCm,
            shouldersCm: changes.shouldersCm,
            chestCm: changes.chestCm,
            waistCm: changes.waistCm,
            hipsCm: changes.hipsCm,
            thighCm: changes.thighCm,
            calfCm: changes.calfCm,
            armCm: changes.armCm,
            forearmCm: changes.forearmCm,
            notes: changes.notes,
          ),
        );
  }
}

final bodyRepositoryProvider = Provider<BodyRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('BodyRepository used while signed out');
  }
  return BodyRepository(ref.watch(appDatabaseProvider), user.id);
});

final bodyMetricsProvider = StreamProvider<List<BodyMetric>>(
  (ref) => ref.watch(bodyRepositoryProvider).watchRecent(),
);

/// The smoothed weight line, straight from the engine.
///
/// Days without a weight are skipped rather than carried: the engine's gap
/// handling already knows what a missed day means, and a measurement row can
/// exist for a day that only recorded a waist.
final weightTrendProvider = Provider<List<engine.TrendPoint>>((ref) {
  final metrics = ref.watch(bodyMetricsProvider).value ?? const [];
  return engine.weightTrend([
    for (final m in metrics)
      if (m.weightKg case final kg?)
        engine.WeighIn(date: parseDayKey(m.measuredOn), weightKg: kg),
  ]);
});

/// Trend weight today, or null before the first weigh-in.
final trendWeightProvider = Provider<double?>(
  (ref) => ref.watch(weightTrendProvider).lastOrNull?.trendKg,
);

/// How fast bodyweight is moving, in kg per week. Null until there is enough
/// history to fit a line to.
final weeklyRateProvider = Provider<double?>(
  (ref) => engine.weeklyRateKg(ref.watch(weightTrendProvider)),
);

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:health/health.dart';
import 'package:logging/logging.dart';

import '../../core/day.dart';
import 'activity_repository.dart';
import 'body_repository.dart';
import 'recovery_repository.dart';

final _log = Logger('health');

/// What Overload reads out of Health Connect. Read-only, and no more than the
/// Move and Body pillars actually use: a permission that is not needed is one
/// more thing to justify at store review and one more thing to leak.
const _types = [
  HealthDataType.STEPS,
  HealthDataType.ACTIVE_ENERGY_BURNED,
  HealthDataType.TOTAL_CALORIES_BURNED,
  HealthDataType.DISTANCE_DELTA,
  HealthDataType.FLIGHTS_CLIMBED,
  HealthDataType.SLEEP_ASLEEP,
  HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
  HealthDataType.RESTING_HEART_RATE,
  HealthDataType.WEIGHT,
];

/// How an import went, so the UI can say something true about it.
enum HealthImportResult {
  imported,

  /// Health Connect is not on this device — most emulators, and any phone
  /// where it has not been installed.
  unavailable,

  /// The lifter has not granted the permissions, or turned them down.
  denied,

  failed,
}

/// Brings steps, sleep and heart data in from Health Connect.
///
/// Imports are re-reads, not appends. Steps keep arriving after midnight, a
/// watch that spent the night charging syncs at breakfast, and Health Connect
/// happily revises yesterday — so every run overwrites the days it covers
/// rather than adding to them. The repositories are built for that.
class HealthImporter {
  HealthImporter(this._activity, this._body, this._recovery);

  final ActivityRepository _activity;
  final BodyRepository _body;
  final RecoveryRepository _recovery;

  Health get _health => Health();

  /// Whether this device has Health Connect at all.
  Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      await _health.configure();
      return await _health.isHealthConnectAvailable();
    } catch (e) {
      _log.info('Health Connect unavailable: $e');
      return false;
    }
  }

  Future<bool> hasPermissions() async {
    try {
      await _health.configure();
      return await _health.hasPermissions(_types, permissions: _readOnly) ??
          false;
    } catch (e) {
      _log.info('Could not read Health permissions: $e');
      return false;
    }
  }

  /// Opens the Health Connect permission sheet. Returns what the lifter chose.
  ///
  /// Must be called from a button press: Android will not show the sheet for a
  /// background request, and asking on launch is how apps get denied forever.
  Future<bool> requestPermissions() async {
    try {
      await _health.configure();
      return await _health.requestAuthorization(_types, permissions: _readOnly);
    } catch (e) {
      _log.warning('Health permission request failed: $e');
      return false;
    }
  }

  static List<HealthDataAccess> get _readOnly =>
      List.filled(_types.length, HealthDataAccess.READ);

  /// Re-reads the last [days] and writes them to the day tables.
  ///
  /// A fortnight by default: long enough to fill in a phone that was off for a
  /// week, short enough not to re-read a year on every app launch.
  Future<HealthImportResult> import({int days = 14}) async {
    if (!await isAvailable()) return HealthImportResult.unavailable;
    if (!await hasPermissions()) return HealthImportResult.denied;

    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: days - 1));

    try {
      final records = await _health.getHealthDataFromTypes(
        types: _types,
        startTime: from,
        endTime: now,
      );
      // Health Connect returns the same reading more than once when several
      // apps wrote it — a phone and a watch both counting steps, say.
      final unique = _health.removeDuplicates(records);
      await _write(unique);
      return HealthImportResult.imported;
    } catch (e, stack) {
      _log.severe('Health import failed', e, stack);
      return HealthImportResult.failed;
    }
  }

  /// Buckets every record by the day it belongs to and writes one row per day.
  Future<void> _write(List<HealthDataPoint> records) async {
    final byDay = <String, List<HealthDataPoint>>{};
    for (final record in records) {
      // A record is filed under the day it *started*: a sleep session that runs
      // past midnight belongs to the night it began, which is the night the
      // lifter is being asked about in the morning.
      (byDay[dayKey(record.dateFrom)] ??= []).add(record);
    }

    for (final MapEntry(key: day, value: points) in byDay.entries) {
      final steps = _sum(points, HealthDataType.STEPS);
      final activeKcal = _sum(points, HealthDataType.ACTIVE_ENERGY_BURNED);
      final totalKcal = _sum(points, HealthDataType.TOTAL_CALORIES_BURNED);
      final distance = _sum(points, HealthDataType.DISTANCE_DELTA);
      final floors = _sum(points, HealthDataType.FLIGHTS_CLIMBED);

      if (steps != null ||
          activeKcal != null ||
          distance != null ||
          floors != null) {
        await _activity.save(
          day: day,
          steps: steps?.round(),
          activeKcal: activeKcal,
          // Health reports the whole day's burn; the resting part is what is
          // left once the active part is taken out of it.
          restingKcal: totalKcal == null || activeKcal == null
              ? null
              : (totalKcal - activeKcal).clamp(0, double.infinity),
          distanceM: distance,
          floors: floors?.round(),
        );
      }

      // Sleep is a duration in minutes summed over the night's sessions; HRV
      // and resting heart rate are single readings, so the latest wins.
      final sleep = _sumMinutes(points, HealthDataType.SLEEP_ASLEEP);
      final hrv = _latest(points, HealthDataType.HEART_RATE_VARIABILITY_RMSSD);
      final restingHr = _latest(points, HealthDataType.RESTING_HEART_RATE);
      if (sleep != null || hrv != null || restingHr != null) {
        await _recovery.saveSignals(
          day: day,
          sleepMinutes: sleep?.round(),
          hrvMs: hrv,
          restingHr: restingHr,
        );
      }

      // A smart scale writes here too. logWeight refuses to overwrite a number
      // the lifter typed themselves.
      if (_latest(points, HealthDataType.WEIGHT) case final kg?) {
        await _body.logWeight(kg, day: day, source: 'health');
      }
    }
  }

  Iterable<HealthDataPoint> _of(
    List<HealthDataPoint> points,
    HealthDataType type,
  ) =>
      points.where((p) => p.type == type);

  double? _sum(List<HealthDataPoint> points, HealthDataType type) {
    final values = _of(points, type).map(_numeric).whereType<double>();
    return values.isEmpty ? null : values.reduce((a, b) => a + b);
  }

  double? _sumMinutes(List<HealthDataPoint> points, HealthDataType type) {
    final sessions = _of(points, type);
    if (sessions.isEmpty) return null;
    return sessions
        .map((p) => p.dateTo.difference(p.dateFrom).inMinutes.toDouble())
        .reduce((a, b) => a + b);
  }

  double? _latest(List<HealthDataPoint> points, HealthDataType type) {
    final sorted = _of(points, type).toList()
      ..sort((a, b) => a.dateFrom.compareTo(b.dateFrom));
    return sorted.isEmpty ? null : _numeric(sorted.last);
  }

  double? _numeric(HealthDataPoint point) {
    final value = point.value;
    return value is NumericHealthValue
        ? value.numericValue.toDouble()
        : null;
  }
}

final healthImporterProvider = Provider<HealthImporter>(
  (ref) => HealthImporter(
    ref.watch(activityRepositoryProvider),
    ref.watch(bodyRepositoryProvider),
    ref.watch(recoveryRepositoryProvider),
  ),
);

/// Whether this device can offer Health at all, so the UI knows whether to
/// mention it.
final healthAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(healthImporterProvider).isAvailable(),
);

final healthPermittedProvider = FutureProvider<bool>(
  (ref) => ref.watch(healthImporterProvider).hasPermissions(),
);

/// Runs one import per app session, when permission is already in place.
///
/// Steps are the one number on the dashboard that nobody should have to press
/// a button for: the phone already counted them. Riverpod caches the future, so
/// this fires once per launch rather than on every rebuild, and it asks for
/// nothing — a device with no permission simply reports `denied` and the UI
/// offers to connect.
final healthAutoImportProvider = FutureProvider<HealthImportResult>(
  (ref) => ref.watch(healthImporterProvider).import(),
);

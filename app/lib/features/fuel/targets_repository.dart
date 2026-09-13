import 'package:drift/drift.dart';
import 'package:engine/engine.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';
import '../../core/profile/profile_repository.dart';
import '../body/activity_repository.dart';
import '../body/body_repository.dart';
import '../train/sessions_repository.dart';
import 'training_rhythm.dart';
import 'meals_repository.dart';

/// What to eat, effective-dated.
///
/// A history rather than a live row. Targets move as the phase changes and as
/// adaptive TDEE learns, and a weekly review that cannot see what the target
/// *was* in March cannot explain March.
class TargetsRepository {
  TargetsRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  /// Every target ever set, newest first.
  Stream<List<NutritionTarget>> watchAll({int limit = 50}) {
    return (_db.select(_db.nutritionTargets)
          ..where((t) => t.userId.equals(_userId))
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.effectiveFrom)])
          ..limit(limit))
        .watch();
  }

  /// The target in force on [day] — the newest one that had started by then.
  Future<NutritionTarget?> forDay([String? day]) async {
    final on = day ?? dayKey();
    final rows = await (_db.select(_db.nutritionTargets)
          ..where((t) => t.userId.equals(_userId))
          ..where((t) => t.deletedAt.isNull())
          ..where((t) => t.effectiveFrom.isSmallerOrEqualValue(on))
          ..orderBy([(t) => OrderingTerm.desc(t.effectiveFrom)])
          ..limit(1))
        .get();
    return rows.firstOrNull;
  }

  /// Stores a target, starting today unless told otherwise.
  ///
  /// Replaces a target already starting that day rather than adding a second —
  /// changing your mind twice before lunch should leave one target, and the
  /// partial unique index in Postgres would refuse the second anyway.
  Future<void> save({
    required engine.MacroTarget target,
    String? day,
    String source = 'engine',
    int? tdeeKcal,
    int? waterMl,
    int? trainingDayCarbShiftPct,
    String? notes,
  }) async {
    final from = day ?? dayKey();
    final existing = await (_db.select(_db.nutritionTargets)
          ..where((t) => t.userId.equals(_userId))
          ..where((t) => t.deletedAt.isNull())
          ..where((t) => t.effectiveFrom.equals(from))
          ..limit(1))
        .getSingleOrNull();

    final changes = NutritionTargetsCompanion(
      kcal: Value(target.kcal),
      proteinG: Value(target.proteinG.toDouble()),
      carbG: Value(target.carbG.toDouble()),
      fatG: Value(target.fatG.toDouble()),
      source: Value(source),
      tdeeKcal: Value(tdeeKcal),
      waterMl: Value(waterMl),
      trainingDayCarbShiftPct: Value(trainingDayCarbShiftPct),
      notes: Value(notes),
      updatedAt: Value(nowUtc()),
    );

    if (existing != null) {
      await (_db.update(_db.nutritionTargets)
            ..where((t) => t.id.equals(existing.id)))
          .write(changes);
      return;
    }

    // Views do not support RETURNING, so the id is generated here. Derived from
    // the day it starts, because one live target per day is a rule Postgres
    // enforces and a random id would collide with the server's own row for it
    // (see CLAUDE.md).
    await _db.into(_db.nutritionTargets).insert(
          NutritionTargetsCompanion.insert(
            id: Value(dayRowId(
              userId: _userId,
              table: 'nutrition_targets',
              day: from,
            )),
            userId: _userId,
            effectiveFrom: from,
            kcal: target.kcal,
            proteinG: target.proteinG.toDouble(),
            carbG: target.carbG.toDouble(),
            fatG: target.fatG.toDouble(),
            source: Value(source),
          ).copyWith(
            tdeeKcal: changes.tdeeKcal,
            waterMl: changes.waterMl,
            trainingDayCarbShiftPct: changes.trainingDayCarbShiftPct,
            notes: changes.notes,
          ),
        );
  }
}

final targetsRepositoryProvider = Provider<TargetsRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('TargetsRepository used while signed out');
  }
  return TargetsRepository(ref.watch(appDatabaseProvider), user.id);
});

final targetHistoryProvider = StreamProvider<List<NutritionTarget>>(
  (ref) => ref.watch(targetsRepositoryProvider).watchAll(),
);

/// The target in force today, or null before one has ever been set.
final todayTargetProvider = Provider<NutritionTarget?>((ref) {
  final history = ref.watch(targetHistoryProvider).value ?? const [];
  final today = dayKey();
  return history
      .where((t) => t.effectiveFrom.compareTo(today) <= 0)
      .firstOrNull;
});

/// What the engine currently believes maintenance is.
///
/// Seeded from Mifflin-St Jeor until there is enough logged food to measure,
/// then measured from intake against weight change. The previous figure comes
/// from the last target that recorded one, so the weekly damping has something
/// to damp against.
final tdeeProvider = FutureProvider<engine.TdeeEstimate>((ref) async {
  final profile = ref.watch(profileProvider).value;
  final trend = ref.watch(weightTrendProvider);
  final history = ref.watch(targetHistoryProvider).value ?? const [];

  final weightKg = trend.lastOrNull?.trendKg;
  final heightCm = profile?.heightCm;
  final birthYear = profile?.birthYear;
  final sex = engine.Sex.fromWire(profile?.sex);

  // Without the basics there is nothing to seed from, and guessing someone's
  // height to produce a calorie target is exactly the kind of invented number
  // this app is supposed to avoid.
  if (weightKg == null || heightCm == null || birthYear == null || sex == null) {
    return const engine.TdeeEstimate(
      kcal: 0,
      status: engine.TdeeStatus.estimating,
      loggedDays: 0,
    );
  }

  final seed = engine.seedTdee(
    weightKg: weightKg,
    heightCm: heightCm,
    ageYears: DateTime.now().year - birthYear,
    sex: sex,
    stepsPerDay: ref.watch(stepAverageProvider(14)) ?? 0,
  );

  final totals =
      await ref.watch(mealsRepositoryProvider).totalsSince(daysAgo(14));
  final intake = [
    for (final MapEntry(:key, :value) in totals.entries)
      if (value.kcal > 0)
        engine.IntakeDay(date: parseDayKey(key), kcal: value.kcal.round()),
  ];

  return engine.estimateTdee(
    intake: intake,
    trend: trend,
    seed: seed,
    previous: history
        .where((t) => t.tdeeKcal != null)
        .firstOrNull
        ?.tdeeKcal
        ?.toDouble(),
  );
});

/// Resting burn from the profile, or null when the profile cannot support one.
///
/// Separate from [tdeeProvider] because the target screen needs it in its own
/// right: a deficit is never allowed to take intake below this, and the screen
/// has to say so when it bites.
final bmrProvider = Provider<double?>((ref) {
  final profile = ref.watch(profileProvider).value;
  final weightKg = ref.watch(weightTrendProvider).lastOrNull?.trendKg;
  final heightCm = profile?.heightCm;
  final birthYear = profile?.birthYear;
  final sex = engine.Sex.fromWire(profile?.sex);

  if (weightKg == null || heightCm == null || birthYear == null || sex == null) {
    return null;
  }
  return engine.basalMetabolicRate(
    weightKg: weightKg,
    heightCm: heightCm,
    ageYears: DateTime.now().year - birthYear,
    sex: sex,
  );
});

/// The target as it applies to one day, after the training-day carb shift.
///
/// The stored row is the *week's* target. docs/PLAN.md §6 allows an optional
/// share of carbohydrate to move from rest days onto training days with the
/// weekly total unchanged, and until now that column was stored, editable and
/// read by nothing — a setting that silently did nothing.
class DayTarget {
  const DayTarget({
    required this.row,
    required this.kcal,
    required this.proteinG,
    required this.carbG,
    required this.fatG,
    required this.shifted,
    required this.isTrainingDay,
  });

  final NutritionTarget row;
  final int kcal;
  final double proteinG;
  final double carbG;
  final double fatG;

  /// Whether the carb shift actually moved anything today.
  final bool shifted;
  final bool isTrainingDay;

  /// What the day would have been without the shift, for explaining it.
  double get baseCarbG => row.carbG;
  int get baseKcal => row.kcal;
}

/// The target in force on [day], shifted for training if that is switched on.
final targetForDayProvider = Provider.family<DayTarget?, String>((ref, day) {
  final history = ref.watch(targetHistoryProvider).value ?? const [];
  final row = history
      .where((t) => t.effectiveFrom.compareTo(day) <= 0)
      .firstOrNull;
  if (row == null) return null;

  final rhythm = ref.watch(trainingRhythmProvider);
  final sessions = ref.watch(recentSessionsProvider).value ?? const [];
  final isTrainingDay = trainsOn(rhythm, day, sessions);
  final pct = row.trainingDayCarbShiftPct ?? 0;

  if (pct <= 0 || !rhythm.canShift) {
    return DayTarget(
      row: row,
      kcal: row.kcal,
      proteinG: row.proteinG,
      carbG: row.carbG,
      fatG: row.fatG,
      shifted: false,
      isTrainingDay: isTrainingDay,
    );
  }

  // The engine owns the arithmetic, here as everywhere else.
  final moved = engine.shiftCarbs(
    target: engine.MacroTarget(
      kcal: row.kcal,
      proteinG: row.proteinG.round(),
      fatG: row.fatG.round(),
      carbG: row.carbG.round(),
      flooredAtBmr: false,
    ),
    shiftPct: pct,
    isTrainingDay: isTrainingDay,
    trainingDaysPerWeek: rhythm.daysPerWeek,
  );

  return DayTarget(
    row: row,
    kcal: moved.kcal,
    proteinG: moved.proteinG.toDouble(),
    carbG: moved.carbG.toDouble(),
    fatG: moved.fatG.toDouble(),
    shifted: moved.carbG != row.carbG.round(),
    isTrainingDay: isTrainingDay,
  );
});

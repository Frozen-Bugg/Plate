import 'package:drift/drift.dart';
import 'package:engine/engine.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

/// What an exercise is prescribed at: the rep range and effort the engine
/// judges the last session against.
///
/// Templates supply this per exercise. The defaults are the spec's example
/// range (docs/PLAN.md §5) — 8–12 reps leaving two in reserve — and apply to
/// anything trained ad hoc, outside any template.
class Prescription {
  const Prescription({
    this.model = engine.ProgressionModel.double_,
    this.sets = 3,
    this.repMin = 8,
    this.repMax = 12,
    this.targetRir = 2,
    this.linearIncrementKg = 2.5,
    this.restSeconds,
  });

  /// Reads a template's row. An unrecognised model falls back to the default
  /// rather than throwing: a bad value in the database should not stop the
  /// lifter getting a target.
  factory Prescription.fromTemplate(TemplateExercise row) {
    engine.ProgressionModel model;
    try {
      model = engine.ProgressionModel.fromWire(row.progressionModel);
    } on ArgumentError {
      model = engine.ProgressionModel.double_;
    }
    return Prescription(
      model: model,
      sets: row.sets,
      repMin: row.repMin,
      repMax: row.repMax,
      targetRir: row.targetRir,
      restSeconds: row.restSeconds,
    );
  }

  final engine.ProgressionModel model;

  /// How many working sets the plan calls for. Not an engine input — double
  /// progression judges the sets actually performed, not the number intended —
  /// but it is what the live screen counts down.
  final int sets;

  final int repMin;
  final int repMax;
  final double? targetRir;
  final double linearIncrementKg;

  /// Rest between sets. Null means the template does not say, and the app's
  /// default applies. Not an engine input — it changes nothing about the next
  /// target — but it rides along with the rest of the prescription.
  final int? restSeconds;
}

/// Turns logged sets into the engine's verdict, and stores it.
///
/// The engine owns the arithmetic; this class only feeds it database rows and
/// writes back what it decides. Nothing here invents a number.
class ProgressionRepository {
  ProgressionRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  Stream<ProgressionState?> watch(String exerciseId) {
    return (_db.select(_db.progressionStates)
          ..where((p) => p.exerciseId.equals(exerciseId))
          ..where((p) => p.userId.equals(_userId))
          ..where((p) => p.deletedAt.isNull())
          ..limit(1))
        .watchSingleOrNull();
  }

  /// Every finished session in which this exercise was trained, oldest first.
  ///
  /// "Exposure" rather than "session": the same exercise can come up twice in
  /// a week, and progression counts appearances, not calendar days.
  Future<List<engine.Exposure>> recentExposures(
    String exerciseId, {
    int limit = 10,
  }) async {
    final se = _db.sessionExercises;
    final s = _db.sessions;

    final rows = await (_db.select(se).join([
      innerJoin(s, s.id.equalsExp(se.sessionId)),
    ])
          ..where(se.exerciseId.equals(exerciseId) &
              se.userId.equals(_userId) &
              se.deletedAt.isNull() &
              s.deletedAt.isNull() &
              s.endedAt.isNotNull())
          ..orderBy([OrderingTerm.desc(s.startedAt)])
          ..limit(limit))
        .get();

    final exposures = <engine.Exposure>[];
    // Newest first from the query; the engine reads oldest first.
    for (final row in rows.reversed) {
      final sets = await (_db.select(_db.workoutSets)
            ..where((x) => x.sessionExerciseId.equals(row.readTable(se).id))
            ..where((x) => x.deletedAt.isNull())
            // Tolerate a null kind: rows written before the column was set
            // explicitly have none, and they were all working sets.
            ..where((x) => x.kind.equals('working') | x.kind.isNull())
            ..orderBy([(x) => OrderingTerm.asc(x.setIndex)]))
          .get();

      final logged = sets
          .where((x) => x.weightKg != null && x.reps != null && x.reps! > 0)
          .map((x) => engine.SetLog(
                weightKg: x.weightKg!,
                reps: x.reps!,
                rir: x.rir,
              ))
          .toList();

      if (logged.isNotEmpty) exposures.add(engine.Exposure(sets: logged));
    }
    return exposures;
  }

  /// Recomputes the verdict for [exerciseId] and stores it.
  ///
  /// Call after finishing a session. Returns the target for next time, or null
  /// when the exercise has never been logged and there is nothing to judge.
  /// [prescription] defaults to whatever a template says about this exercise,
  /// falling back to the spec's example range when no template covers it.
  Future<engine.NextTarget?> recompute(
    String exerciseId, {
    Prescription? prescription,
  }) async {
    final exposures = await recentExposures(exerciseId);
    if (exposures.isEmpty) {
      // Every session containing this exercise has been deleted, so the stored
      // target was derived from sets that no longer count. Showing it would be
      // worse than showing nothing.
      await _clear(exerciseId);
      return null;
    }

    prescription ??= await prescriptionFor(exerciseId);

    final exercise = await (_db.select(_db.exercises)
          ..where((e) => e.id.equals(exerciseId)))
        .getSingleOrNull();
    final loadStepKg = exercise?.loadStepKg ?? 2.5;

    final last = exposures.last;
    final stallCount = engine.stallCount(exposures);

    final target = switch (prescription.model) {
      engine.ProgressionModel.linear => engine.LinearProgression(
          incrementKg: prescription.linearIncrementKg,
          reps: prescription.repMin,
        ).next(last: last, consecutiveFailures: stallCount),
      // Only double and linear exist in engine v1; the rest arrive with v2, so
      // until then they fall back to the default model rather than guessing.
      _ => engine.DoubleProgression(
          repMin: prescription.repMin,
          repMax: prescription.repMax,
          loadStepKg: loadStepKg,
          targetRir: prescription.targetRir,
        ).next(last: last),
    };

    final bestE1rm = exposures
        .map((e) => e.bestE1rm)
        .reduce((a, b) => a > b ? a : b);

    await _upsert(
      exerciseId: exerciseId,
      model: prescription.model,
      target: target,
      stallCount: stallCount,
      bestE1rmKg: bestE1rm,
    );
    return target;
  }

  /// The prescription a template gives for [exerciseId], or the default when
  /// no template covers it.
  Future<Prescription> prescriptionFor(String exerciseId) async {
    final rows = await (_db.select(_db.templateExercises)
          ..where((e) => e.exerciseId.equals(exerciseId))
          ..where((e) => e.userId.equals(_userId))
          ..where((e) => e.deletedAt.isNull())
          ..orderBy([(e) => OrderingTerm.desc(e.updatedAt)])
          ..limit(1))
        .get();
    final row = rows.firstOrNull;
    return row == null ? const Prescription() : Prescription.fromTemplate(row);
  }

  /// Whether the engine considers this exercise stalled — no e1RM gain across
  /// three exposures at the same or higher effort.
  Future<bool> isStalled(String exerciseId) async =>
      engine.isStalled(await recentExposures(exerciseId));

  /// Drops the stored verdict for an exercise with no history left.
  Future<void> _clear(String exerciseId) =>
      (_db.update(_db.progressionStates)
            ..where((p) => p.exerciseId.equals(exerciseId))
            ..where((p) => p.userId.equals(_userId))
            ..where((p) => p.deletedAt.isNull()))
          .write(
        ProgressionStatesCompanion(
          deletedAt: Value(nowUtc()),
          updatedAt: Value(nowUtc()),
        ),
      );

  Future<void> _upsert({
    required String exerciseId,
    required engine.ProgressionModel model,
    required engine.NextTarget target,
    required int stallCount,
    required double bestE1rmKg,
  }) async {
    final existing = await (_db.select(_db.progressionStates)
          ..where((p) => p.exerciseId.equals(exerciseId))
          ..where((p) => p.userId.equals(_userId))
          ..limit(1))
        .getSingleOrNull();

    final changes = ProgressionStatesCompanion(
      model: Value(model.wireName),
      nextLoadKg: Value(target.loadKg),
      nextReps: Value(target.reps),
      stallCount: Value(stallCount),
      bestE1rmKg: Value(bestE1rmKg),
      deletedAt: const Value(null),
      updatedAt: Value(nowUtc()),
    );

    if (existing == null) {
      // Views do not support RETURNING, so the id is generated here.
      await _db.into(_db.progressionStates).insert(
            ProgressionStatesCompanion.insert(
              id: Value(uuid.v7()),
              userId: _userId,
              exerciseId: exerciseId,
              model: Value(model.wireName),
              nextLoadKg: Value(target.loadKg),
              nextReps: Value(target.reps),
              stallCount: Value(stallCount),
              bestE1rmKg: Value(bestE1rmKg),
            ),
          );
    } else {
      await (_db.update(_db.progressionStates)
            ..where((p) => p.id.equals(existing.id)))
          .write(changes);
    }
  }
}

final progressionRepositoryProvider = Provider<ProgressionRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('ProgressionRepository used while signed out');
  }
  return ProgressionRepository(ref.watch(appDatabaseProvider), user.id);
});

final progressionStateProvider =
    StreamProvider.family<ProgressionState?, String>(
  (ref, exerciseId) => ref.watch(progressionRepositoryProvider).watch(exerciseId),
);

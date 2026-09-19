import 'package:drift/drift.dart';
import 'package:engine/engine.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';
import 'progression_repository.dart';

/// Workout templates and the prescription they carry for each exercise.
///
/// A template is the plan, kept for its prescription — sets, rep range,
/// target effort, model — which is what the engine judges an exercise
/// against once it has been trained. What actually happened comes in through
/// hevy_import.dart, not from starting a template.
class TemplatesRepository {
  TemplatesRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  Stream<List<Template>> watchAll() {
    return (_db.select(_db.templates)
          ..where((t) => t.userId.equals(_userId))
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.asc(t.dayIndex),
            (t) => OrderingTerm.asc(t.name),
          ]))
        .watch();
  }

  Stream<List<TemplateExercise>> watchExercises(String templateId) {
    return (_db.select(_db.templateExercises)
          ..where((e) => e.templateId.equals(templateId))
          ..where((e) => e.deletedAt.isNull())
          ..orderBy([(e) => OrderingTerm.asc(e.position)]))
        .watch();
  }

  /// The prescription that applies to [exerciseId] — whichever template
  /// mentioning it was edited most recently. A stream rather than a one-off
  /// read so an edit made mid-session shows up straight away.
  Stream<TemplateExercise?> watchPrescriptionFor(String exerciseId) {
    return (_db.select(_db.templateExercises)
          ..where((e) => e.exerciseId.equals(exerciseId))
          ..where((e) => e.userId.equals(_userId))
          ..where((e) => e.deletedAt.isNull())
          ..orderBy([(e) => OrderingTerm.desc(e.updatedAt)])
          ..limit(1))
        .watchSingleOrNull();
  }

  Future<String> create({required String name, int dayIndex = 0}) async {
    // Views do not support RETURNING, so the id is generated here.
    final id = uuid.v7();
    await _db
        .into(_db.templates)
        .insert(
          TemplatesCompanion.insert(
            id: Value(id),
            userId: _userId,
            name: name,
            // PowerSync's local tables carry no DEFAULT, so every non-nullable
            // column has to be written — see CLAUDE.md.
            dayIndex: Value(dayIndex),
          ),
        );
    return id;
  }

  Future<void> rename(String templateId, String name) =>
      (_db.update(_db.templates)..where((t) => t.id.equals(templateId))).write(
        TemplatesCompanion(name: Value(name), updatedAt: Value(nowUtc())),
      );

  /// Cascades to the exercises in the template, for the same reason deleting a
  /// session does: a soft delete does not trigger the foreign key, and a
  /// surviving template_exercise still answers prescriptionFor — so a deleted
  /// template would go on dictating rep ranges and rest times forever.
  Future<void> delete(String templateId) async {
    final now = nowUtc();
    await (_db.update(_db.templateExercises)
          ..where((e) => e.templateId.equals(templateId))
          ..where((e) => e.deletedAt.isNull()))
        .write(
          TemplateExercisesCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    await (_db.update(
      _db.templates,
    )..where((t) => t.id.equals(templateId))).write(
      TemplatesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  Future<String> addExercise({
    required String templateId,
    required String exerciseId,
  }) async {
    final existing =
        await (_db.select(_db.templateExercises)
              ..where((e) => e.templateId.equals(templateId))
              ..where((e) => e.deletedAt.isNull()))
            .get();

    final id = uuid.v7();
    await _db
        .into(_db.templateExercises)
        .insert(
          TemplateExercisesCompanion.insert(
            id: Value(id),
            userId: _userId,
            templateId: templateId,
            exerciseId: exerciseId,
            position: Value(existing.length),
            sets: const Value(3),
            repMin: const Value(8),
            repMax: const Value(12),
            targetRir: const Value(2),
            progressionModel: Value(engine.ProgressionModel.double_.wireName),
          ),
        );
    return id;
  }

  /// Rewrites `position` for every exercise in the template to match
  /// [orderedIds] — the drag-reordered list, front to back.
  ///
  /// One transaction rather than one write per row: a reorder is a single
  /// gesture, and a partial write left by a crash mid-reorder would leave two
  /// exercises sharing a position, which sorts arbitrarily forever after.
  Future<void> reorderExercises(
    String templateId,
    List<String> orderedIds,
  ) async {
    final now = nowUtc();
    await _db.transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (_db.update(_db.templateExercises)
              ..where((e) => e.id.equals(orderedIds[i]))
              ..where((e) => e.templateId.equals(templateId)))
            .write(
              TemplateExercisesCompanion(
                position: Value(i),
                updatedAt: Value(now),
              ),
            );
      }
    });
  }

  Future<void> removeExercise(String templateExerciseId) =>
      (_db.update(
        _db.templateExercises,
      )..where((e) => e.id.equals(templateExerciseId))).write(
        TemplateExercisesCompanion(
          deletedAt: Value(nowUtc()),
          updatedAt: Value(nowUtc()),
        ),
      );

  /// [sets], [repMin], [repMax] and [model] are not nullable in the database,
  /// so null means "leave it alone". [targetRir] and [restSeconds] are, and
  /// clearing them is meaningful — blank RIR means effort is not judged, blank
  /// rest means the app default — so they take a [Value] and can be set to
  /// null deliberately.
  Future<void> updatePrescription(
    String templateExerciseId, {
    int? sets,
    int? repMin,
    int? repMax,
    engine.ProgressionModel? model,
    Value<double?> targetRir = const Value.absent(),
    Value<int?> restSeconds = const Value.absent(),
  }) =>
      (_db.update(
        _db.templateExercises,
      )..where((e) => e.id.equals(templateExerciseId))).write(
        TemplateExercisesCompanion(
          sets: sets == null ? const Value.absent() : Value(sets),
          repMin: repMin == null ? const Value.absent() : Value(repMin),
          repMax: repMax == null ? const Value.absent() : Value(repMax),
          progressionModel: model == null
              ? const Value.absent()
              : Value(model.wireName),
          targetRir: targetRir,
          restSeconds: restSeconds,
          updatedAt: Value(nowUtc()),
        ),
      );
}

final templatesRepositoryProvider = Provider<TemplatesRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('TemplatesRepository used while signed out');
  }
  return TemplatesRepository(ref.watch(appDatabaseProvider), user.id);
});

final templatesProvider = StreamProvider<List<Template>>(
  (ref) => ref.watch(templatesRepositoryProvider).watchAll(),
);

final templateExercisesProvider =
    StreamProvider.family<List<TemplateExercise>, String>(
      (ref, templateId) =>
          ref.watch(templatesRepositoryProvider).watchExercises(templateId),
    );

/// What an exercise is prescribed at, live. Falls back to the default for
/// anything no template covers, so the live screen always has something to
/// count against.
final prescriptionProvider = StreamProvider.family<Prescription, String>(
  (ref, exerciseId) => ref
      .watch(templatesRepositoryProvider)
      .watchPrescriptionFor(exerciseId)
      .map(
        (row) =>
            row == null ? const Prescription() : Prescription.fromTemplate(row),
      ),
);

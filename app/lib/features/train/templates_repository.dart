import 'package:drift/drift.dart';
import 'package:engine/engine.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';
import 'logging_repository.dart';
import 'sessions_repository.dart';

/// Workout templates and the prescription they carry for each exercise.
///
/// A template is the plan; a session is what actually happened. Starting from
/// a template copies its exercises into the session, and the prescription —
/// sets, rep range, target effort, model — is what the engine judges the
/// session against afterwards.
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

  Future<String> create({required String name, int dayIndex = 0}) async {
    // Views do not support RETURNING, so the id is generated here.
    final id = uuid.v7();
    await _db.into(_db.templates).insert(
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

  Future<void> delete(String templateId) =>
      (_db.update(_db.templates)..where((t) => t.id.equals(templateId))).write(
        TemplatesCompanion(
          deletedAt: Value(nowUtc()),
          updatedAt: Value(nowUtc()),
        ),
      );

  Future<String> addExercise({
    required String templateId,
    required String exerciseId,
  }) async {
    final existing = await (_db.select(_db.templateExercises)
          ..where((e) => e.templateId.equals(templateId))
          ..where((e) => e.deletedAt.isNull()))
        .get();

    final id = uuid.v7();
    await _db.into(_db.templateExercises).insert(
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
            progressionModel:
                Value(engine.ProgressionModel.double_.wireName),
          ),
        );
    return id;
  }

  Future<void> removeExercise(String templateExerciseId) =>
      (_db.update(_db.templateExercises)
            ..where((e) => e.id.equals(templateExerciseId)))
          .write(
        TemplateExercisesCompanion(
          deletedAt: Value(nowUtc()),
          updatedAt: Value(nowUtc()),
        ),
      );

  Future<void> updatePrescription(
    String templateExerciseId, {
    int? sets,
    int? repMin,
    int? repMax,
    double? targetRir,
    engine.ProgressionModel? model,
    int? restSeconds,
  }) =>
      (_db.update(_db.templateExercises)
            ..where((e) => e.id.equals(templateExerciseId)))
          .write(
        TemplateExercisesCompanion(
          sets: sets == null ? const Value.absent() : Value(sets),
          repMin: repMin == null ? const Value.absent() : Value(repMin),
          repMax: repMax == null ? const Value.absent() : Value(repMax),
          targetRir:
              targetRir == null ? const Value.absent() : Value(targetRir),
          progressionModel:
              model == null ? const Value.absent() : Value(model.wireName),
          restSeconds:
              restSeconds == null ? const Value.absent() : Value(restSeconds),
          updatedAt: Value(nowUtc()),
        ),
      );

  /// Starts a session and copies the template's exercises into it, in order.
  /// Returns the new session's id.
  Future<String> startSession(String templateId) async {
    final planned = await watchExercises(templateId).first;
    final sessions = SessionsRepository(_db, _userId);
    final sessionId = await sessions.start(templateId: templateId);

    final logging = LoggingRepository(_db, _userId);
    for (final exercise in planned) {
      await logging.addExercise(
        sessionId: sessionId,
        exerciseId: exercise.exerciseId,
      );
    }
    return sessionId;
  }
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

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

/// The equipment a movement uses, in the order a gym is usually laid out.
///
/// Matches the check constraint on `exercises.equipment`: anything not in this
/// list is refused by Postgres after the upload, which is the worst place to
/// find out.
const equipmentKinds = <String>[
  'barbell',
  'dumbbell',
  'machine',
  'cable',
  'bodyweight',
  'kettlebell',
  'band',
  'other',
];

/// The smallest jump the equipment can actually make, in kilograms.
///
/// The engine adds one step when a lifter clears their target, so this decides
/// what "a bit more next time" means. A barbell takes 1.25 kg plates a side;
/// a dumbbell rack jumps in 2s; a machine's pin usually moves in 5s.
double defaultLoadStep(String equipment) => switch (equipment) {
  'barbell' => 2.5,
  'dumbbell' => 2.0,
  'machine' || 'cable' => 5.0,
  'band' || 'bodyweight' => 1.0,
  _ => 2.5,
};

/// The exercise library: the seeded movements everyone gets, plus anything the
/// lifter has added themselves.
class ExercisesRepository {
  ExercisesRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  /// Seeded rows carry a null `user_id`; custom ones carry the owner's. Both
  /// belong in the picker, ordered by name.
  Stream<List<Exercise>> watchLibrary() {
    return (_db.select(_db.exercises)
          ..where((e) => e.userId.isNull() | e.userId.equals(_userId))
          ..where((e) => e.deletedAt.isNull())
          ..orderBy([(e) => OrderingTerm.asc(e.name)]))
        .watch();
  }

  Future<Exercise?> byId(String id) => (_db.select(
    _db.exercises,
  )..where((e) => e.id.equals(id))).getSingleOrNull();

  /// The closest existing exercise to [name], for matching something named
  /// from outside the app — see hevy_import.dart. An exact match wins;
  /// otherwise whichever row's name contains the other, the same
  /// contains-based fuzz `FoodsRepository.bestMatch` uses for the same
  /// reason: an imported name rarely spells a movement exactly the way this
  /// library does.
  Future<Exercise?> bestMatch(String name) async {
    final needle = name.trim().toLowerCase();
    if (needle.isEmpty) return null;

    final rows =
        await (_db.select(_db.exercises)
              ..where((e) => e.userId.isNull() | e.userId.equals(_userId))
              ..where((e) => e.deletedAt.isNull()))
            .get();

    Exercise? contained;
    for (final exercise in rows) {
      final candidate = exercise.name.trim().toLowerCase();
      if (candidate == needle) return exercise;
      if (contained == null &&
          (candidate.contains(needle) || needle.contains(candidate))) {
        contained = exercise;
      }
    }
    return contained;
  }

  /// Adds a movement the seeded library does not have.
  ///
  /// Returns the existing row instead of a second one when the name is already
  /// taken, case- and space-insensitively. A lifter who types "Pendlay Row"
  /// twice a fortnight apart means the same exercise both times, and two rows
  /// would split its history in half — which is the one thing the progression
  /// engine cannot recover from.
  ///
  /// Every non-nullable column is written explicitly: PowerSync creates the
  /// local tables without DEFAULT clauses, so anything omitted lands as NULL
  /// and Postgres refuses the upload (see CLAUDE.md).
  Future<Exercise> create({
    required String name,
    String equipment = 'other',
    double? loadStepKg,
    bool unilateral = false,
    List<String> primaryMuscles = const [],
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'An exercise needs a name');
    }
    if (await byName(trimmed) case final existing?) return existing;

    final kind = equipmentKinds.contains(equipment) ? equipment : 'other';
    // PowerSync tables are views, so RETURNING does not work: make the id here.
    final id = uuid.v7();
    await _db
        .into(_db.exercises)
        .insert(
          ExercisesCompanion.insert(
            id: Value(id),
            userId: Value(_userId),
            name: trimmed,
            equipment: Value(kind),
            unilateral: Value(unilateral),
            loadStepKg: Value(loadStepKg ?? defaultLoadStep(kind)),
            primaryMuscles: Value(primaryMuscles),
            secondaryMuscles: const Value([]),
          ),
        );
    return (await byId(id))!;
  }

  /// An exercise by name, ignoring case and surrounding space. Searches the
  /// seeded library as well as the lifter's own, so "Bench Press" finds the one
  /// that already exists rather than making a private duplicate of it.
  Future<Exercise?> byName(String name) async {
    final needle = name.trim().toLowerCase();
    if (needle.isEmpty) return null;
    final candidates =
        await (_db.select(_db.exercises)
              ..where((e) => e.userId.isNull() | e.userId.equals(_userId))
              ..where((e) => e.deletedAt.isNull())
              ..where((e) => e.name.lower().equals(needle)))
            .get();
    // The lifter's own wins over a seeded one of the same name: if they made
    // it, they meant to.
    for (final candidate in candidates) {
      if (candidate.userId != null) return candidate;
    }
    return candidates.firstOrNull;
  }

  /// Renames a custom exercise, or changes how it loads.
  ///
  /// Seeded rows are not editable — they carry a null `user_id`, the RLS policy
  /// refuses the update, and the write would be dropped from the queue and
  /// recorded as a rejection rather than silently ignored.
  Future<void> update(
    String id, {
    String? name,
    String? equipment,
    double? loadStepKg,
    bool? unilateral,
  }) =>
      (_db.update(_db.exercises)
            ..where((e) => e.id.equals(id))
            ..where((e) => e.userId.equals(_userId)))
          .write(
            ExercisesCompanion(
              name: name == null ? const Value.absent() : Value(name.trim()),
              equipment: equipment == null
                  ? const Value.absent()
                  : Value(equipment),
              loadStepKg: loadStepKg == null
                  ? const Value.absent()
                  : Value(loadStepKg),
              unilateral: unilateral == null
                  ? const Value.absent()
                  : Value(unilateral),
              updatedAt: Value(nowUtc()),
            ),
          );

  /// Soft-deletes a custom exercise so it leaves the picker on every device.
  ///
  /// The sets logged against it are left alone on purpose: they are history,
  /// and history does not stop having happened because the movement was
  /// retired. They keep rendering from their own stored numbers.
  Future<void> delete(String id) =>
      (_db.update(_db.exercises)
            ..where((e) => e.id.equals(id))
            ..where((e) => e.userId.equals(_userId)))
          .write(
            ExercisesCompanion(
              deletedAt: Value(nowUtc()),
              updatedAt: Value(nowUtc()),
            ),
          );
}

final exercisesRepositoryProvider = Provider<ExercisesRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('ExercisesRepository used while signed out');
  }
  return ExercisesRepository(ref.watch(appDatabaseProvider), user.id);
});

final exerciseLibraryProvider = StreamProvider<List<Exercise>>(
  (ref) => ref.watch(exercisesRepositoryProvider).watchLibrary(),
);

/// The library keyed by id.
///
/// Every screen that renders a set needs the movement's name, and scanning the
/// whole library once per row per rebuild is how a workout with six exercises
/// and twenty sets turns into hundreds of scans a frame.
final exercisesByIdProvider = Provider<Map<String, Exercise>>((ref) {
  final library = ref.watch(exerciseLibraryProvider).value ?? const [];
  return {for (final exercise in library) exercise.id: exercise};
});

/// One exercise from the library, or null while it is still loading.
final exerciseByIdProvider = Provider.family<Exercise?, String>(
  (ref, id) => ref.watch(exercisesByIdProvider)[id],
);

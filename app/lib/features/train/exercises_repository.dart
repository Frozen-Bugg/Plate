import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

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

  Future<Exercise?> byId(String id) =>
      (_db.select(_db.exercises)..where((e) => e.id.equals(id)))
          .getSingleOrNull();
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

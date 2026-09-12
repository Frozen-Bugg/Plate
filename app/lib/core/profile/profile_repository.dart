import 'package:drift/drift.dart';
import 'package:engine/engine.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_service.dart';
import '../db/app_database.dart';
import '../db/database_providers.dart';

/// The signed-in lifter's profile row.
///
/// Created by a trigger on sign-up, so this only ever reads and updates — there
/// is no insert path, and a profile that has not arrived yet means the first
/// sync has not finished.
class ProfileRepository {
  ProfileRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  Stream<Profile?> watch() => (_db.select(_db.profiles)
        ..where((p) => p.id.equals(_userId))
        ..limit(1))
      .watchSingleOrNull();

  Future<void> update(ProfilesCompanion changes) =>
      (_db.update(_db.profiles)..where((p) => p.id.equals(_userId)))
          .write(changes.copyWith(updatedAt: Value(nowUtc())));

  /// Which way the lifter wants the scale to go. Everything that judges the
  /// trend needs it, and 'maintain' is the schema's default.
  Future<void> setPhase(engine.WeightPhase phase) =>
      update(ProfilesCompanion(phase: Value(phase.wireName)));
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('ProfileRepository used while signed out');
  }
  return ProfileRepository(ref.watch(appDatabaseProvider), user.id);
});

final profileProvider = StreamProvider<Profile?>(
  (ref) => ref.watch(profileRepositoryProvider).watch(),
);

/// The lifter's current phase, defaulting to maintenance.
///
/// Falls back rather than throwing on an unrecognised value: a profile row that
/// has not synced yet, or one written by a newer version of the app, should not
/// stop the Progress screen rendering.
final weightPhaseProvider = Provider<engine.WeightPhase>((ref) {
  final stored = ref.watch(profileProvider).value?.phase;
  if (stored == null) return engine.WeightPhase.maintain;
  try {
    return engine.WeightPhase.fromWire(stored);
  } on ArgumentError {
    return engine.WeightPhase.maintain;
  }
});

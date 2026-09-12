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
  Future<void> setPhase(engine.WeightPhase phase) async {
    await ensureExists();
    await update(ProfilesCompanion(phase: Value(phase.wireName)));
  }

  /// Creates the profile row if this account somehow has none.
  ///
  /// A trigger on `auth.users` normally writes it at sign-up, so the row is
  /// there for anyone who signed up after that trigger existed — and missing
  /// for anyone who did not. Without it every write here updates zero rows and
  /// says nothing, which is how a phase picker ends up doing nothing at all.
  ///
  /// Only call once the first sync has finished. An empty table on a fresh
  /// install means "not downloaded yet", not "not there", and inserting then
  /// would upsert defaults over a real profile.
  ///
  /// Every non-nullable column is written explicitly: PowerSync creates the
  /// local tables without DEFAULT clauses (see CLAUDE.md).
  Future<bool> ensureExists() async {
    final existing = await (_db.select(_db.profiles)
          ..where((p) => p.id.equals(_userId))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return false;

    await _db.into(_db.profiles).insert(
          ProfilesCompanion.insert(
            id: _userId,
            experience: const Value('novice'),
            unitSystem: const Value('metric'),
            phase: const Value('maintain'),
            equipment: const Value([]),
            injuries: const Value('[]'),
            timezone: Value(DateTime.now().timeZoneName),
          ),
        );
    return true;
  }
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

/// Makes sure a profile row exists, once the first sync has settled.
///
/// Waiting for the sync matters: an empty `profiles` table on a fresh install
/// means the row has not arrived yet, and writing one then would upsert
/// defaults over the real thing.
final profileKeeperProvider = Provider<void>((ref) {
  final synced = ref.watch(syncStatusProvider).value?.hasSynced ?? false;
  if (!synced) return;
  // Depend on the row itself, so this re-runs if it is ever removed.
  if (ref.watch(profileProvider).value != null) return;

  ref.read(profileRepositoryProvider).ensureExists();
});

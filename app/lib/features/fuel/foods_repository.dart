import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

/// A food as it arrives from outside: a search result, a barcode lookup, a
/// scanned label. Not yet the lifter's, and not yet stored.
class FoodFacts {
  const FoodFacts({
    required this.name,
    required this.kcalPer100,
    this.brand,
    this.source = 'custom',
    this.sourceId,
    this.barcode,
    this.basis = 'g',
    this.proteinPer100 = 0,
    this.carbPer100 = 0,
    this.fatPer100 = 0,
    this.fibrePer100,
    this.sugarPer100,
    this.satFatPer100,
    this.sodiumMgPer100,
    this.servingG,
    this.servingLabel,
  });

  final String name;
  final String? brand;

  /// 'custom', 'usda', 'off', 'label' or 'coach'.
  final String source;

  /// The id this food has wherever it came from, so the same one is recognised
  /// next time rather than copied again.
  final String? sourceId;
  final String? barcode;

  /// 'g' or 'ml'.
  final String basis;

  final double kcalPer100;
  final double proteinPer100;
  final double carbPer100;
  final double fatPer100;
  final double? fibrePer100;
  final double? sugarPer100;
  final double? satFatPer100;
  final double? sodiumMgPer100;
  final double? servingG;
  final String? servingLabel;
}

/// The foods this lifter has actually used.
///
/// Not a food database — a copy of the parts of one that matter to them. The
/// real databases are millions of rows, so search goes out to the network and
/// anything used comes back here, where it syncs and works offline. Basement
/// gyms and aeroplanes are where food logging happens.
class FoodsRepository {
  FoodsRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  /// Most recently used first — which is what a food log actually needs, since
  /// people eat the same thirty things.
  Stream<List<Food>> watchRecent({int limit = 50}) {
    return (_db.select(_db.foods)
          ..where((f) => f.userId.equals(_userId))
          ..where((f) => f.deletedAt.isNull())
          ..orderBy([
            (f) => OrderingTerm.desc(f.favourite),
            (f) => OrderingTerm.desc(f.lastUsedAt),
            (f) => OrderingTerm.desc(f.createdAt),
          ])
          ..limit(limit))
        .watch();
  }

  /// Local search across what the lifter already has, which is the only search
  /// that works offline and the one that answers most of the time.
  Stream<List<Food>> watchMatching(String query, {int limit = 50}) {
    final term = '%${query.trim().toLowerCase()}%';
    return (_db.select(_db.foods)
          ..where((f) => f.userId.equals(_userId))
          ..where((f) => f.deletedAt.isNull())
          ..where((f) => f.name.lower().like(term) | f.brand.lower().like(term))
          ..orderBy([
            (f) => OrderingTerm.desc(f.lastUsedAt),
            (f) => OrderingTerm.asc(f.name),
          ])
          ..limit(limit))
        .watch();
  }

  Future<Food?> byId(String id) => (_db.select(_db.foods)
        ..where((f) => f.id.equals(id))
        ..where((f) => f.deletedAt.isNull())
        ..limit(1))
      .getSingleOrNull();

  Future<Food?> byBarcode(String barcode) => (_db.select(_db.foods)
        ..where((f) => f.userId.equals(_userId))
        ..where((f) => f.deletedAt.isNull())
        ..where((f) => f.barcode.equals(barcode))
        ..limit(1))
      .getSingleOrNull();

  /// Stores [facts] as the lifter's own food, or finds the copy already there.
  ///
  /// This is the copy-on-use path, and it is deliberately idempotent: scanning
  /// the same tin every Tuesday should find one food with a fresh
  /// `last_used_at`, not fifty-two identical rows. Matching is by barcode
  /// first — the strongest identity a food has — then by where it came from.
  Future<Food> remember(FoodFacts facts) async {
    final existing = await _match(facts);
    if (existing != null) {
      await touch(existing.id);
      return (await byId(existing.id))!;
    }

    final id = uuid.v7();
    // Views do not support RETURNING, so the id is generated here, and every
    // non-nullable column is written explicitly (see CLAUDE.md).
    await _db.into(_db.foods).insert(
          FoodsCompanion.insert(
            id: Value(id),
            userId: _userId,
            name: facts.name,
            kcalPer100: facts.kcalPer100,
            source: Value(facts.source),
            basis: Value(facts.basis),
            proteinPer100: Value(facts.proteinPer100),
            carbPer100: Value(facts.carbPer100),
            fatPer100: Value(facts.fatPer100),
            favourite: const Value(false),
          ).copyWith(
            brand: Value(facts.brand),
            sourceId: Value(facts.sourceId),
            barcode: Value(facts.barcode),
            fibrePer100: Value(facts.fibrePer100),
            sugarPer100: Value(facts.sugarPer100),
            satFatPer100: Value(facts.satFatPer100),
            sodiumMgPer100: Value(facts.sodiumMgPer100),
            servingG: Value(facts.servingG),
            servingLabel: Value(facts.servingLabel),
            lastUsedAt: Value(nowUtc()),
          ),
        );
    return (await byId(id))!;
  }

  /// The copy already on this device, if there is one.
  Future<Food?> _match(FoodFacts facts) async {
    if (facts.barcode case final barcode?) {
      final byCode = await byBarcode(barcode);
      if (byCode != null) return byCode;
    }
    if (facts.sourceId case final sourceId? when facts.source != 'custom') {
      final rows = await (_db.select(_db.foods)
            ..where((f) => f.userId.equals(_userId))
            ..where((f) => f.deletedAt.isNull())
            ..where((f) => f.source.equals(facts.source))
            ..where((f) => f.sourceId.equals(sourceId))
            ..limit(1))
          .get();
      if (rows.firstOrNull case final match?) return match;
    }
    return null;
  }

  /// Marks a food as used just now, which is what orders the recents list.
  Future<void> touch(String id) =>
      (_db.update(_db.foods)..where((f) => f.id.equals(id))).write(
        FoodsCompanion(lastUsedAt: Value(nowUtc()), updatedAt: Value(nowUtc())),
      );

  Future<void> setFavourite(String id, {required bool favourite}) =>
      (_db.update(_db.foods)..where((f) => f.id.equals(id))).write(
        FoodsCompanion(
          favourite: Value(favourite),
          updatedAt: Value(nowUtc()),
        ),
      );

  Future<void> update(String id, FoodsCompanion changes) =>
      (_db.update(_db.foods)..where((f) => f.id.equals(id)))
          .write(changes.copyWith(updatedAt: Value(nowUtc())));

  /// Soft delete, always.
  ///
  /// A food that has been eaten cannot be hard-deleted — Postgres refuses it,
  /// deliberately, so that a logged day stays exactly as it was logged. Taking
  /// it off the list is all this does.
  Future<void> delete(String id) {
    final now = nowUtc();
    return (_db.update(_db.foods)..where((f) => f.id.equals(id)))
        .write(FoodsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
  }
}

final foodsRepositoryProvider = Provider<FoodsRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('FoodsRepository used while signed out');
  }
  return FoodsRepository(ref.watch(appDatabaseProvider), user.id);
});

final recentFoodsProvider = StreamProvider<List<Food>>(
  (ref) => ref.watch(foodsRepositoryProvider).watchRecent(),
);

/// Foods matching what has been typed so far. Empty query returns recents,
/// because an empty search box should still be useful.
final foodSearchProvider = StreamProvider.family<List<Food>, String>(
  (ref, query) => query.trim().isEmpty
      ? ref.watch(foodsRepositoryProvider).watchRecent()
      : ref.watch(foodsRepositoryProvider).watchMatching(query),
);

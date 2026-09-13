import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

/// One line of a shopping list, with the food behind it when there is one.
class GroceryLine {
  const GroceryLine({required this.item, required this.food});

  final GroceryItem item;
  final Food? food;

  String get id => item.id;
  String get name => item.name;
  bool get checked => item.checked;

  /// How much to buy, in units a shop uses.
  ///
  /// A list in grams is a list written for a database. 1,340 g of chicken is
  /// "1.4 kg", twelve eggs are "12", and a splash of oil is "30 g" because
  /// that is genuinely what it is.
  String get amount {
    final grams = item.quantityG;
    if (grams == null || grams <= 0) return '';

    // Something sold by the piece, when the food knows what a piece weighs and
    // the amount is close to a whole number of them.
    if (food?.servingG case final serving? when serving > 0) {
      final count = grams / serving;
      if (count >= 1 && (count - count.round()).abs() < 0.15) {
        final label = food?.servingLabel;
        return label == null || label.isEmpty
            ? '${count.round()}'
            : '${count.round()} × $label';
      }
    }

    if (grams >= 1000) {
      final kg = grams / 1000;
      return '${kg.toStringAsFixed(kg >= 10 ? 0 : 1)} kg';
    }
    return '${grams.round()} g';
  }
}

/// A list and its lines.
class GroceryList {
  const GroceryList({required this.list, required this.lines});

  final GroceryListRow list;
  final List<GroceryLine> lines;

  String get id => list.id;
  String get name => list.name;

  List<GroceryLine> get outstanding =>
      [for (final line in lines) if (!line.checked) line];

  int get left => outstanding.length;
  bool get isDone => lines.isNotEmpty && left == 0;
}

/// Shopping lists, and the lines on them.
class GroceriesRepository {
  GroceriesRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  /// Every list with its lines, newest first.
  Stream<List<GroceryList>> watchLists() {
    final lists = _db.groceryLists;
    final items = _db.groceryItems;
    final foods = _db.foods;

    final query = _db.select(lists).join([
      leftOuterJoin(
        items,
        items.listId.equalsExp(lists.id) & items.deletedAt.isNull(),
      ),
      leftOuterJoin(
        foods,
        foods.id.equalsExp(items.foodId) & foods.deletedAt.isNull(),
      ),
    ])
      ..where(lists.userId.equals(_userId) & lists.deletedAt.isNull())
      ..orderBy([
        OrderingTerm.desc(lists.createdAt),
        OrderingTerm.asc(items.position),
      ]);

    return query.watch().map((rows) {
      final order = <String>[];
      final heads = <String, GroceryListRow>{};
      final parts = <String, List<GroceryLine>>{};

      for (final row in rows) {
        final list = row.readTable(lists);
        if (!heads.containsKey(list.id)) {
          heads[list.id] = list;
          order.add(list.id);
        }
        if (row.readTableOrNull(items) case final item?) {
          (parts[list.id] ??= []).add(
            GroceryLine(item: item, food: row.readTableOrNull(foods)),
          );
        }
      }

      return [
        for (final id in order)
          GroceryList(list: heads[id]!, lines: parts[id] ?? const []),
      ];
    });
  }

  /// Builds a list from a set of ingredients, summed by food.
  ///
  /// [wanted] is every ingredient of every planned cook, in the order they came
  /// out of the plan. The chicken in three different meals is one line on the
  /// list, which is the whole reason this is not just a copy of the plan.
  Future<String> build({
    required List<({String name, String? foodId, double grams})> wanted,
    String name = 'This week',
    String? forWeek,
  }) async {
    final id = uuid.v7();
    await _db.into(_db.groceryLists).insert(
          GroceryListsCompanion.insert(
            id: Value(id),
            userId: _userId,
            name: Value(name),
            forWeek: Value(forWeek ?? dayKey()),
          ),
        );

    // Summed by food where there is one, and by name where there is not — an
    // ingredient nothing matched still has to appear, or the list is short and
    // the shopping trip comes back incomplete.
    final totals = <String, ({String name, String? foodId, double grams})>{};
    for (final line in wanted) {
      final key = line.foodId ?? 'name:${line.name.trim().toLowerCase()}';
      final running = totals[key];
      totals[key] = (
        name: running?.name ?? line.name,
        foodId: line.foodId,
        grams: (running?.grams ?? 0) + line.grams,
      );
    }

    var position = 0;
    for (final line in totals.values) {
      await _db.into(_db.groceryItems).insert(
            GroceryItemsCompanion.insert(
              id: Value(uuid.v7()),
              userId: _userId,
              listId: id,
              name: line.name,
              quantityG: Value(line.grams),
              fromPlan: const Value(true),
              checked: const Value(false),
              position: Value(position++),
            ).copyWith(foodId: Value(line.foodId)),
          );
    }
    return id;
  }

  /// Adds a line by hand. Half a shopping list is not food.
  Future<String> add({
    required String listId,
    required String name,
    double? grams,
  }) async {
    final existing = await (_db.select(_db.groceryItems)
          ..where((i) => i.listId.equals(listId))
          ..where((i) => i.deletedAt.isNull()))
        .get();
    final position = existing.isEmpty
        ? 0
        : existing.map((i) => i.position).reduce((a, b) => a > b ? a : b) + 1;

    final id = uuid.v7();
    await _db.into(_db.groceryItems).insert(
          GroceryItemsCompanion.insert(
            id: Value(id),
            userId: _userId,
            listId: listId,
            name: name,
            quantityG: Value(grams),
            fromPlan: const Value(false),
            checked: const Value(false),
            position: Value(position),
          ),
        );
    return id;
  }

  Future<void> setChecked(String itemId, {required bool checked}) =>
      (_db.update(_db.groceryItems)..where((i) => i.id.equals(itemId))).write(
        GroceryItemsCompanion(
          checked: Value(checked),
          updatedAt: Value(nowUtc()),
        ),
      );

  Future<void> removeLine(String itemId) {
    final now = nowUtc();
    return (_db.update(_db.groceryItems)..where((i) => i.id.equals(itemId)))
        .write(GroceryItemsCompanion(
      deletedAt: Value(now),
      updatedAt: Value(now),
    ));
  }

  /// Soft delete, cascading by hand.
  Future<void> deleteList(String id) async {
    final now = nowUtc();
    await (_db.update(_db.groceryItems)
          ..where((i) => i.listId.equals(id))
          ..where((i) => i.deletedAt.isNull()))
        .write(GroceryItemsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
    await (_db.update(_db.groceryLists)..where((l) => l.id.equals(id)))
        .write(GroceryListsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
  }
}

final groceriesRepositoryProvider = Provider<GroceriesRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('GroceriesRepository used while signed out');
  }
  return GroceriesRepository(ref.watch(appDatabaseProvider), user.id);
});

final groceryListsProvider = StreamProvider<List<GroceryList>>(
  (ref) => ref.watch(groceriesRepositoryProvider).watchLists(),
);

/// The list being shopped from, which is the newest one with anything left.
final currentGroceryListProvider = Provider<GroceryList?>((ref) {
  final lists = ref.watch(groceryListsProvider).value ?? const <GroceryList>[];
  for (final list in lists) {
    if (!list.isDone) return list;
  }
  return lists.firstOrNull;
});

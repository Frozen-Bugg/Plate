import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';
import 'foods_repository.dart';

/// What a set of items adds up to.
typedef Nutrition = ({
  double kcal,
  double proteinG,
  double carbG,
  double fatG,
  double fibreG,
});

const _nothing = (kcal: 0.0, proteinG: 0.0, carbG: 0.0, fatG: 0.0, fibreG: 0.0);

/// The slots a day is divided into. Order matters — it is the order the day is
/// read in, not alphabetical.
const mealSlots = ['breakfast', 'lunch', 'dinner', 'snack'];

/// One day's eating, already assembled.
class DayLog {
  const DayLog({required this.day, required this.meals, required this.items});

  final String day;
  final List<Meal> meals;
  final List<MealItem> items;

  List<MealItem> itemsIn(String mealId) =>
      items.where((i) => i.mealId == mealId).toList()
        ..sort((a, b) => a.position.compareTo(b.position));

  Nutrition get total => totalOf(items);

  Nutrition totalIn(String mealId) => totalOf(itemsIn(mealId));

  bool get isEmpty => items.isEmpty;

  static Nutrition totalOf(List<MealItem> items) => items.fold(
        _nothing,
        (sum, i) => (
          kcal: sum.kcal + i.kcal,
          proteinG: sum.proteinG + i.proteinG,
          carbG: sum.carbG + i.carbG,
          fatG: sum.fatG + i.fatG,
          fibreG: sum.fibreG + (i.fibreG ?? 0),
        ),
      );
}

/// Meals and the items in them.
///
/// Several meals a day, so this is not one of the one-row-per-day tables: the
/// day is a query over `meal_on`, and the totals for a day live in
/// `daily_rollup` once they are worth keeping.
class MealsRepository {
  MealsRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  /// Every item eaten on [day], across all its meals.
  ///
  /// Joined in SQL rather than fetched per meal: a day has four or five meals
  /// and a query each would mean five round trips on every keystroke elsewhere.
  /// A whole day — its slots and everything in them — from one query.
  ///
  /// One watched join rather than two streams combined. Drift re-emits a joined
  /// query when *either* table changes, so the slots and the items can never
  /// disagree. They used to: the day was built with `asyncExpand`, which waits
  /// for the inner stream to finish before handling the next outer event, and a
  /// `.watch()` never finishes. The meals list froze on its first emission while
  /// the items kept updating, so a newly created slot held food that the totals
  /// counted and the screen did not show.
  ///
  /// A left join keeps an empty slot, which matters because an empty lunch is
  /// information.
  Stream<DayLog> watchDayLog(String day) {
    final meals = _db.meals;
    final items = _db.mealItems;

    final query = _db.select(meals).join([
      leftOuterJoin(
        items,
        items.mealId.equalsExp(meals.id) & items.deletedAt.isNull(),
      ),
    ])
      ..where(meals.userId.equals(_userId) &
          meals.deletedAt.isNull() &
          meals.mealOn.equals(day))
      ..orderBy([
        OrderingTerm.asc(meals.loggedAt),
        OrderingTerm.asc(items.position),
      ]);

    return query.watch().map((rows) {
      final slots = <String, Meal>{};
      final logged = <MealItem>[];

      for (final row in rows) {
        final meal = row.readTable(meals);
        slots.putIfAbsent(meal.id, () => meal);
        if (row.readTableOrNull(items) case final item?) logged.add(item);
      }

      return DayLog(day: day, meals: slots.values.toList(), items: logged);
    });
  }

  /// Totals per day since [from], updating as food is logged.
  ///
  /// The rollup watches this: a meal logged at midday should move the day's
  /// summary at midday, not whenever something else happens to trigger a
  /// rebuild.
  Stream<Map<String, Nutrition>> watchTotalsSince(String from) {
    final items = _db.mealItems;
    final meals = _db.meals;
    return (_db.select(items).join([
      innerJoin(meals, meals.id.equalsExp(items.mealId)),
    ])
          ..where(items.userId.equals(_userId) &
              items.deletedAt.isNull() &
              meals.deletedAt.isNull() &
              meals.mealOn.isBiggerOrEqualValue(from)))
        .watch()
        .map((rows) {
      final byDay = <String, List<MealItem>>{};
      for (final row in rows) {
        (byDay[row.readTable(meals).mealOn] ??= []).add(row.readTable(items));
      }
      return {
        for (final MapEntry(:key, :value) in byDay.entries)
          key: DayLog.totalOf(value),
      };
    });
  }

  /// Totals for a range of days, for the rollup and for Progress.
  Future<Map<String, Nutrition>> totalsSince(String from) async {
    final items = _db.mealItems;
    final meals = _db.meals;
    final rows = await (_db.select(items).join([
      innerJoin(meals, meals.id.equalsExp(items.mealId)),
    ])
          ..where(items.userId.equals(_userId) &
              items.deletedAt.isNull() &
              meals.deletedAt.isNull() &
              meals.mealOn.isBiggerOrEqualValue(from)))
        .get();

    final byDay = <String, List<MealItem>>{};
    for (final row in rows) {
      (byDay[row.readTable(meals).mealOn] ??= []).add(row.readTable(items));
    }
    return {
      for (final MapEntry(:key, :value) in byDay.entries)
        key: DayLog.totalOf(value),
    };
  }

  /// Finds the meal for a slot on a day, or starts one.
  ///
  /// Slots are containers rather than events: a lifter who grazes all afternoon
  /// should end up with one "snack" holding six things, not six snacks.
  Future<String> mealFor({required String slot, String? day}) async {
    final on = day ?? dayKey();
    final existing = await (_db.select(_db.meals)
          ..where((m) => m.userId.equals(_userId))
          ..where((m) => m.deletedAt.isNull())
          ..where((m) => m.mealOn.equals(on))
          ..where((m) => m.slot.equals(slot))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return existing.id;

    // Views do not support RETURNING, so the id is generated here, and every
    // non-nullable column is written explicitly (see CLAUDE.md).
    final id = uuid.v7();
    await _db.into(_db.meals).insert(
          MealsCompanion.insert(
            id: Value(id),
            userId: _userId,
            mealOn: on,
            slot: Value(slot),
            loggedAt: Value(nowUtc()),
          ),
        );
    return id;
  }

  /// Logs [quantityG] of [food] into a slot.
  ///
  /// The macros are worked out here and stored on the item. That is the whole
  /// point: a food database correction next November must not rewrite what this
  /// March says was eaten.
  Future<String> logFood({
    required Food food,
    required double quantityG,
    String slot = 'snack',
    String? day,
    String source = 'manual',
  }) async {
    final mealId = await mealFor(slot: slot, day: day);
    final macros = nutritionFor(food, quantityG);
    final id = uuid.v7();

    await _db.into(_db.mealItems).insert(
          MealItemsCompanion.insert(
            id: Value(id),
            userId: _userId,
            mealId: mealId,
            quantityG: quantityG,
            kcal: macros.kcal,
            position: Value(await _nextPosition(mealId)),
            proteinG: Value(macros.proteinG),
            carbG: Value(macros.carbG),
            fatG: Value(macros.fatG),
            source: Value(source),
          ).copyWith(
            foodId: Value(food.id),
            fibreG: Value(food.fibrePer100 == null ? null : macros.fibreG),
          ),
        );

    // Keeps the recents list in the order a food log actually needs.
    await FoodsRepository(_db, _userId).touch(food.id);
    return id;
  }

  /// Changes how much of something was eaten, and rescales what it contained.
  Future<void> setQuantity(MealItem item, double quantityG) async {
    final food =
        item.foodId == null ? null : await FoodsRepository(_db, _userId).byId(item.foodId!);

    // Without the food to recompute from — it was deleted, or the item came
    // from a recipe — scale what was stored. The ratio is the honest fallback:
    // it keeps the item's own numbers rather than inventing new ones.
    final macros = food != null
        ? nutritionFor(food, quantityG)
        : _scaled(item, quantityG);

    await (_db.update(_db.mealItems)..where((i) => i.id.equals(item.id))).write(
      MealItemsCompanion(
        quantityG: Value(quantityG),
        kcal: Value(macros.kcal),
        proteinG: Value(macros.proteinG),
        carbG: Value(macros.carbG),
        fatG: Value(macros.fatG),
        fibreG: Value(item.fibreG == null ? null : macros.fibreG),
        updatedAt: Value(nowUtc()),
      ),
    );
  }

  Nutrition _scaled(MealItem item, double quantityG) {
    if (item.quantityG <= 0) return _nothing;
    final factor = quantityG / item.quantityG;
    return (
      kcal: item.kcal * factor,
      proteinG: item.proteinG * factor,
      carbG: item.carbG * factor,
      fatG: item.fatG * factor,
      fibreG: (item.fibreG ?? 0) * factor,
    );
  }

  Future<void> deleteItem(String id) {
    final now = nowUtc();
    return (_db.update(_db.mealItems)..where((i) => i.id.equals(id))).write(
      MealItemsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  /// Soft delete, cascading by hand.
  ///
  /// Postgres cascades the composite key on a hard delete; this is a soft one,
  /// and without marking the items too they stay in the database forever,
  /// invisible to every screen and still counted by anything that sums them.
  Future<void> deleteMeal(String id) async {
    final now = nowUtc();
    await (_db.update(_db.mealItems)
          ..where((i) => i.mealId.equals(id))
          ..where((i) => i.deletedAt.isNull()))
        .write(MealItemsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
    await (_db.update(_db.meals)..where((m) => m.id.equals(id)))
        .write(MealsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
  }

  Future<int> _nextPosition(String mealId) async {
    final rows = await (_db.select(_db.mealItems)
          ..where((i) => i.mealId.equals(mealId))
          ..where((i) => i.deletedAt.isNull()))
        .get();
    return rows.isEmpty
        ? 0
        : rows.map((i) => i.position).reduce((a, b) => a > b ? a : b) + 1;
  }
}

/// What [quantityG] of [food] contains.
///
/// Unit conversion, not a decision — the engine owns what the numbers *mean*,
/// this only scales what the label says. Nutrition is stored per 100 g or
/// 100 ml, so a portion is always a multiplication.
Nutrition nutritionFor(Food food, double quantityG) {
  final factor = quantityG / 100;
  return (
    kcal: food.kcalPer100 * factor,
    proteinG: food.proteinPer100 * factor,
    carbG: food.carbPer100 * factor,
    fatG: food.fatPer100 * factor,
    fibreG: (food.fibrePer100 ?? 0) * factor,
  );
}

final mealsRepositoryProvider = Provider<MealsRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('MealsRepository used while signed out');
  }
  return MealsRepository(ref.watch(appDatabaseProvider), user.id);
});

/// The day the Fuel screen is showing. Today unless the lifter goes looking.
class FuelDay extends Notifier<String> {
  @override
  String build() => dayKey();

  void show(String day) => state = day;

  /// Steps [by] days from the day on screen — yesterday is the common case,
  /// because food gets logged after the fact more often than anyone admits.
  void step(int by) => state = dayKey(parseDayKey(state).add(Duration(days: by)));

  void today() => state = dayKey();
}

final fuelDayProvider =
    NotifierProvider<FuelDay, String>(FuelDay.new);

final dayLogProvider = StreamProvider.family<DayLog, String>((ref, day) {
  final repository = ref.watch(mealsRepositoryProvider);
  // Both streams, combined: meals give the day its shape, items give it its
  // numbers, and the screen needs them together.
  return repository.watchDayLog(day);
});

/// Intake per day over the last fortnight, which is the window the rollup
/// rewrites and the window adaptive TDEE measures over.
final recentIntakeProvider = StreamProvider<Map<String, Nutrition>>(
  (ref) => ref.watch(mealsRepositoryProvider).watchTotalsSince(daysAgo(13)),
);

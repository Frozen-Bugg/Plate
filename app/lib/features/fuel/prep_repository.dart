import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';
import 'meals_repository.dart';
import 'recipes_repository.dart';

/// A batch row with the grams already taken out of it.
///
/// Kept separate from [Batch] because this is what one query can answer; the
/// recipe behind it comes from a stream that is already running.
typedef BatchRow = ({PrepBatch batch, double gramsEaten});

/// A cook, and what is left of it.
///
/// Nothing here is stored except the cook itself. Servings remaining is
/// arithmetic over the portions logged against the batch, which is why two
/// phones can log lunch at the same time without inventing a third portion.
class Batch {
  const Batch({
    required this.batch,
    required this.recipe,
    required this.gramsEaten,
  });

  final PrepBatch batch;

  /// Null when the recipe has been deleted but the batch has not.
  final RecipeDetail? recipe;

  final double gramsEaten;

  String get id => batch.id;
  String get name => recipe?.name ?? 'Deleted recipe';
  String get cookedOn => batch.cookedOn;
  int get servingsMade => batch.servingsMade;

  /// What the whole batch weighed.
  ///
  /// The batch's own measurement first: the recipe's expected yield is what
  /// seeded it, but this pot is the one in the fridge.
  double get weightG => batch.cookedWeightG ?? recipe?.weightG ?? 0;

  bool get isWeighed => batch.cookedWeightG != null;

  double get servingWeightG =>
      servingsMade > 0 ? weightG / servingsMade : weightG;

  double get gramsLeft {
    final left = weightG - gramsEaten;
    return left > 0 ? left : 0;
  }

  /// Portions left, which can be a fraction — half a serving is still lunch.
  double get servingsLeft =>
      servingWeightG > 0 ? gramsLeft / servingWeightG : 0;

  /// Under a tenth of a serving is an empty tub, not a meal.
  bool get isFinished => servingsLeft < 0.1;

  /// What a serving of it contains.
  Nutrition get perServing => nutritionForGrams(servingWeightG);

  /// What [grams] out of *this pot* contains.
  ///
  /// Scaled against the batch's weight, never the recipe's. The pot holds the
  /// recipe's ingredients whatever it weighs, so a chilli cooked down twenty
  /// minutes longer is the same food in less water: fewer grams per serving,
  /// identical macros. Delegating this to the recipe divided by the wrong
  /// weight and quietly under-counted every reduced sauce.
  Nutrition nutritionForGrams(double grams) {
    final recipe = this.recipe;
    if (recipe == null || weightG <= 0) {
      return (kcal: 0.0, proteinG: 0.0, carbG: 0.0, fatG: 0.0, fibreG: 0.0);
    }
    return recipe.scaledBy(grams / weightG);
  }

  /// Days until it stops being food. Negative once it has.
  int? get daysLeft {
    if (batch.useBy case final by?) {
      return parseDayKey(by).difference(parseDayKey(dayKey())).inDays;
    }
    return null;
  }

  bool get isPastUseBy => (daysLeft ?? 1) < 0;

  /// Worth saying something about: there is food left and it is running out.
  ///
  /// Wasted prep is the main reason people stop prepping, so this is the one
  /// thing in the feature that earns an interruption.
  bool get needsEating => !isFinished && (daysLeft ?? 99) <= 1;
}

/// Cooks, and the portions taken out of them.
class PrepRepository {
  PrepRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  /// Every batch with the grams already logged against it.
  ///
  /// One watched left join. A batch nobody has eaten from yet still appears,
  /// which is the whole point of the outer join — an untouched batch is the
  /// most useful kind.
  Stream<List<BatchRow>> watchBatchRows() {
    final batches = _db.prepBatches;
    final items = _db.mealItems;

    final query = _db.select(batches).join([
      leftOuterJoin(
        items,
        items.prepBatchId.equalsExp(batches.id) & items.deletedAt.isNull(),
      ),
    ])
      ..where(batches.userId.equals(_userId) & batches.deletedAt.isNull())
      ..orderBy([OrderingTerm.desc(batches.cookedOn)]);

    return query.watch().map((rows) {
      final order = <String>[];
      final heads = <String, PrepBatch>{};
      final eaten = <String, double>{};

      for (final row in rows) {
        final batch = row.readTable(batches);
        if (!heads.containsKey(batch.id)) {
          heads[batch.id] = batch;
          order.add(batch.id);
        }
        if (row.readTableOrNull(items) case final item?) {
          eaten[batch.id] = (eaten[batch.id] ?? 0) + item.quantityG;
        }
      }

      return [
        for (final id in order)
          (batch: heads[id]!, gramsEaten: eaten[id] ?? 0),
      ];
    });
  }

  /// Records a cook.
  ///
  /// [cookedWeightG] is seeded from the recipe's expected yield by the UI and
  /// corrected on the scales. Null means it was not weighed, and portions fall
  /// back to the recipe's weight with the screen saying so.
  Future<String> logCook({
    required String recipeId,
    required int servingsMade,
    double? cookedWeightG,
    String? cookedOn,
    String? useBy,
    String? notes,
  }) async {
    final id = uuid.v7();
    await _db.into(_db.prepBatches).insert(
          PrepBatchesCompanion.insert(
            id: Value(id),
            userId: _userId,
            recipeId: recipeId,
            cookedOn: cookedOn ?? dayKey(),
            servingsMade: servingsMade,
            cookedWeightG: Value(cookedWeightG),
            useBy: Value(useBy),
            notes: Value(notes),
          ),
        );
    return id;
  }

  Future<void> update(
    String id, {
    int? servingsMade,
    double? cookedWeightG,
    String? useBy,
    bool clearUseBy = false,
  }) =>
      (_db.update(_db.prepBatches)..where((b) => b.id.equals(id))).write(
        PrepBatchesCompanion(
          servingsMade:
              servingsMade == null ? const Value.absent() : Value(servingsMade),
          cookedWeightG: cookedWeightG == null
              ? const Value.absent()
              : Value(cookedWeightG),
          useBy: clearUseBy
              ? const Value(null)
              : (useBy == null ? const Value.absent() : Value(useBy)),
          updatedAt: Value(nowUtc()),
        ),
      );

  /// Throws the rest away.
  ///
  /// Soft delete, and the portions already eaten out of it stay exactly as they
  /// are — they are history, and they carry their own macros.
  Future<void> discard(String id) {
    final now = nowUtc();
    return (_db.update(_db.prepBatches)..where((b) => b.id.equals(id))).write(
      PrepBatchesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  /// Eats some of it.
  ///
  /// Writes one `meal_items` row carrying both the recipe and the batch. The
  /// recipe is what it was; the batch is which pot it came out of, and is what
  /// makes the remainder derivable.
  Future<String> logPortion({
    required Batch batch,
    required double grams,
    String slot = 'lunch',
    String? day,
  }) async {
    final recipe = batch.recipe;
    if (recipe == null) {
      throw StateError('Cannot log a portion of a deleted recipe');
    }

    final meals = MealsRepository(_db, _userId);
    final mealId = await meals.mealFor(slot: slot, day: day);
    final macros = batch.nutritionForGrams(grams);
    final id = uuid.v7();

    final existing = await (_db.select(_db.mealItems)
          ..where((i) => i.mealId.equals(mealId))
          ..where((i) => i.deletedAt.isNull()))
        .get();
    final position = existing.isEmpty
        ? 0
        : existing.map((i) => i.position).reduce((a, b) => a > b ? a : b) + 1;

    await _db.into(_db.mealItems).insert(
          MealItemsCompanion.insert(
            id: Value(id),
            userId: _userId,
            mealId: mealId,
            quantityG: grams,
            kcal: macros.kcal,
            position: Value(position),
            proteinG: Value(macros.proteinG),
            carbG: Value(macros.carbG),
            fatG: Value(macros.fatG),
            source: const Value('prep'),
          ).copyWith(
            recipeId: Value(recipe.id),
            prepBatchId: Value(batch.id),
            fibreG: Value(macros.fibreG),
          ),
        );

    await RecipesRepository(_db, _userId).touch(recipe.id);
    return id;
  }
}

final prepRepositoryProvider = Provider<PrepRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('PrepRepository used while signed out');
  }
  return PrepRepository(ref.watch(appDatabaseProvider), user.id);
});

final batchRowsProvider = StreamProvider<List<BatchRow>>(
  (ref) => ref.watch(prepRepositoryProvider).watchBatchRows(),
);

/// Batches with their recipes attached.
///
/// Two streams joined in Dart rather than a four-table SQL join. The recipes
/// stream is already running for the recipes screen, and `asyncExpand` — the
/// obvious way to chain them — waits for the inner stream to *complete*, which
/// a `.watch()` never does. That froze the meals list once already.
final prepBatchesProvider = Provider<List<Batch>>((ref) {
  final recipes = ref.watch(recipesProvider).value ?? const <RecipeDetail>[];
  final rows = ref.watch(batchRowsProvider).value ?? const <BatchRow>[];
  final byId = {for (final r in recipes) r.id: r};

  return [
    for (final row in rows)
      Batch(
        batch: row.batch,
        recipe: byId[row.batch.recipeId],
        gramsEaten: row.gramsEaten,
      ),
  ];
});

/// What is actually in the fridge: still has food in it, still edible.
///
/// The order is what to eat first — the batch closest to its use-by, then the
/// oldest cook.
final prepOnHandProvider = Provider<List<Batch>>((ref) {
  final all = [
    for (final batch in ref.watch(prepBatchesProvider))
      if (!batch.isFinished && !batch.isPastUseBy) batch,
  ];

  all.sort((a, b) {
    final byUseBy = (a.daysLeft ?? 999).compareTo(b.daysLeft ?? 999);
    return byUseBy != 0 ? byUseBy : a.cookedOn.compareTo(b.cookedOn);
  });
  return all;
});

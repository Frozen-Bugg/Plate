import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';
import 'meals_repository.dart';

/// One ingredient, with the food it points at.
///
/// The food travels with the item because every number on a recipe screen is
/// derived from it. `recipe_items.food_id` is NOT NULL in the schema, so an
/// ingredient always has one — but it can be soft-deleted out from under a
/// recipe, which is why [food] is nullable here and the UI says so.
class Ingredient {
  const Ingredient({required this.item, required this.food});

  final RecipeItem item;
  final Food? food;

  String get id => item.id;
  double get quantityG => item.quantityG;
  String get name => food?.name ?? 'Deleted food';

  /// What this much of it contains. Zero for a missing food rather than a
  /// guess: a recipe that quietly under-counts is worse than one that shows a
  /// gap.
  Nutrition get nutrition =>
      food == null ? _nothing : nutritionFor(food!, quantityG);
}

const _nothing = (kcal: 0.0, proteinG: 0.0, carbG: 0.0, fatG: 0.0, fibreG: 0.0);

/// A recipe and everything in it.
///
/// Macros are computed from the food rows every time rather than stored. A
/// recipe is a *plan*, so it should follow a corrected food; a logged meal is
/// history, so it must not. That asymmetry is deliberate — see the note on
/// `meal_items` in the schema.
class RecipeDetail {
  const RecipeDetail({required this.recipe, required this.ingredients});

  final Recipe recipe;
  final List<Ingredient> ingredients;

  String get id => recipe.id;
  String get name => recipe.name;
  int get servings => recipe.servings ?? 1;

  /// What the whole pot contains.
  Nutrition get total => ingredients.fold(
        _nothing,
        (sum, i) => (
          kcal: sum.kcal + i.nutrition.kcal,
          proteinG: sum.proteinG + i.nutrition.proteinG,
          carbG: sum.carbG + i.nutrition.carbG,
          fatG: sum.fatG + i.nutrition.fatG,
          fibreG: sum.fibreG + i.nutrition.fibreG,
        ),
      );

  Nutrition get perServing => scaledBy(1 / servings);

  Nutrition scaledBy(double factor) => (
        kcal: total.kcal * factor,
        proteinG: total.proteinG * factor,
        carbG: total.carbG * factor,
        fatG: total.fatG * factor,
        fibreG: total.fibreG * factor,
      );

  /// What the ingredients weigh before anything is cooked off.
  double get rawWeightG =>
      ingredients.fold(0.0, (sum, i) => sum + i.quantityG);

  /// What the finished dish weighs.
  ///
  /// `total_weight_g` when it was measured, raw weight otherwise. The
  /// difference is water: rice doubles, a stew reduces, and portioning by raw
  /// weight is how prep macros go wrong everywhere else.
  double get weightG =>
      recipe.totalWeightG ?? (rawWeightG > 0 ? rawWeightG : 0);

  bool get isWeighed => recipe.totalWeightG != null;

  /// What one serving weighs, for logging by portion.
  double get servingWeightG => servings > 0 ? weightG / servings : weightG;

  /// What [grams] of the finished dish contains.
  ///
  /// Macros come from the raw ingredients; portions come from the cooked
  /// weight. Both halves of that sentence are in this one expression.
  Nutrition nutritionForGrams(double grams) =>
      weightG <= 0 ? _nothing : scaledBy(grams / weightG);

  bool get isEmpty => ingredients.isEmpty;
}

/// Recipes and the ingredients in them.
class RecipesRepository {
  RecipesRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  /// Every recipe with its ingredients, newest use first.
  ///
  /// One watched three-way join rather than a query per recipe. Drift re-emits
  /// when any of the three tables changes, so a food edited in one screen moves
  /// every recipe that uses it without anything having to invalidate anything.
  Stream<List<RecipeDetail>> watchRecipes() {
    final recipes = _db.recipes;
    final items = _db.recipeItems;
    final foods = _db.foods;

    final query = _db.select(recipes).join([
      leftOuterJoin(
        items,
        items.recipeId.equalsExp(recipes.id) & items.deletedAt.isNull(),
      ),
      leftOuterJoin(
        foods,
        foods.id.equalsExp(items.foodId) & foods.deletedAt.isNull(),
      ),
    ])
      ..where(recipes.userId.equals(_userId) & recipes.deletedAt.isNull())
      ..orderBy([
        OrderingTerm.desc(recipes.favourite),
        OrderingTerm.desc(recipes.lastUsedAt),
        OrderingTerm.desc(recipes.createdAt),
        OrderingTerm.asc(items.position),
      ]);

    return query.watch().map(_group);
  }

  /// One recipe, watched.
  Stream<RecipeDetail?> watchRecipe(String id) => watchRecipes()
      .map((all) => all.where((r) => r.id == id).firstOrNull);

  List<RecipeDetail> _group(List<TypedResult> rows) {
    final recipes = _db.recipes;
    final items = _db.recipeItems;
    final foods = _db.foods;

    final order = <String>[];
    final heads = <String, Recipe>{};
    final parts = <String, List<Ingredient>>{};

    for (final row in rows) {
      final recipe = row.readTable(recipes);
      if (!heads.containsKey(recipe.id)) {
        heads[recipe.id] = recipe;
        // The query's ordering is the answer; a map does not keep it.
        order.add(recipe.id);
      }
      if (row.readTableOrNull(items) case final item?) {
        (parts[recipe.id] ??= []).add(
          Ingredient(item: item, food: row.readTableOrNull(foods)),
        );
      }
    }

    return [
      for (final id in order)
        RecipeDetail(
          recipe: heads[id]!,
          ingredients: parts[id] ?? const [],
        ),
    ];
  }

  Future<RecipeDetail?> byId(String id) => watchRecipe(id).first;

  /// Starts a recipe. Ingredients are added after, one at a time.
  Future<String> create({
    required String name,
    int servings = 1,
    double? totalWeightG,
    String? notes,
  }) async {
    // Views do not support RETURNING, so the id is generated here.
    final id = uuid.v7();
    await _db.into(_db.recipes).insert(
          RecipesCompanion.insert(
            id: Value(id),
            userId: _userId,
            name: name,
            servings: Value(servings),
            totalWeightG: Value(totalWeightG),
            notes: Value(notes),
            favourite: const Value(false),
          ),
        );
    return id;
  }

  Future<void> update(
    String id, {
    String? name,
    int? servings,
    double? totalWeightG,
    bool clearTotalWeight = false,
    String? notes,
    bool? favourite,
  }) =>
      (_db.update(_db.recipes)..where((r) => r.id.equals(id))).write(
        RecipesCompanion(
          name: name == null ? const Value.absent() : Value(name),
          servings: servings == null ? const Value.absent() : Value(servings),
          totalWeightG: clearTotalWeight
              ? const Value(null)
              : (totalWeightG == null
                  ? const Value.absent()
                  : Value(totalWeightG)),
          notes: notes == null ? const Value.absent() : Value(notes),
          favourite:
              favourite == null ? const Value.absent() : Value(favourite),
          updatedAt: Value(nowUtc()),
        ),
      );

  /// Soft delete, cascading by hand.
  ///
  /// Postgres cascades the composite key on a hard delete; this is a soft one,
  /// and unmarked items stay forever — invisible to every screen and still
  /// summed by anything that counts them.
  Future<void> delete(String id) async {
    final now = nowUtc();
    await (_db.update(_db.recipeItems)
          ..where((i) => i.recipeId.equals(id))
          ..where((i) => i.deletedAt.isNull()))
        .write(RecipeItemsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
    await (_db.update(_db.recipes)..where((r) => r.id.equals(id)))
        .write(RecipesCompanion(deletedAt: Value(now), updatedAt: Value(now)));
  }

  Future<String> addIngredient({
    required String recipeId,
    required String foodId,
    required double quantityG,
  }) async {
    final id = uuid.v7();
    await _db.into(_db.recipeItems).insert(
          RecipeItemsCompanion.insert(
            id: Value(id),
            userId: _userId,
            recipeId: recipeId,
            foodId: foodId,
            quantityG: quantityG,
            position: Value(await _nextPosition(recipeId)),
          ),
        );
    return id;
  }

  Future<void> setIngredientQuantity(String itemId, double quantityG) =>
      (_db.update(_db.recipeItems)..where((i) => i.id.equals(itemId))).write(
        RecipeItemsCompanion(
          quantityG: Value(quantityG),
          updatedAt: Value(nowUtc()),
        ),
      );

  Future<void> removeIngredient(String itemId) {
    final now = nowUtc();
    return (_db.update(_db.recipeItems)..where((i) => i.id.equals(itemId)))
        .write(RecipeItemsCompanion(
      deletedAt: Value(now),
      updatedAt: Value(now),
    ));
  }

  /// Logs [grams] of a recipe into a slot.
  ///
  /// Writes one `meal_items` row carrying `recipe_id` and the macros *as they
  /// are now*. The item is a fact about what was eaten, so it does not follow
  /// the recipe afterwards — editing the recipe tomorrow must not rewrite what
  /// today says was eaten.
  Future<String> logToMeal({
    required RecipeDetail recipe,
    required double grams,
    String slot = 'snack',
    String? day,
    String source = 'manual',
  }) async {
    final meals = MealsRepository(_db, _userId);
    final mealId = await meals.mealFor(slot: slot, day: day);
    final macros = recipe.nutritionForGrams(grams);
    final id = uuid.v7();

    await _db.into(_db.mealItems).insert(
          MealItemsCompanion.insert(
            id: Value(id),
            userId: _userId,
            mealId: mealId,
            quantityG: grams,
            kcal: macros.kcal,
            position: Value(await _nextMealPosition(mealId)),
            proteinG: Value(macros.proteinG),
            carbG: Value(macros.carbG),
            fatG: Value(macros.fatG),
            source: Value(source),
          ).copyWith(
            recipeId: Value(recipe.id),
            fibreG: Value(macros.fibreG),
          ),
        );

    await touch(recipe.id);
    return id;
  }

  /// Turns a meal that was already logged into a reusable recipe.
  ///
  /// The cheapest useful thing in the whole feature: the recipes worth having
  /// are the meals already eaten, and this asks for a name rather than a form.
  ///
  /// Only items that came from a food can be carried over — `recipe_items`
  /// requires a `food_id`, and an item logged from another recipe has none.
  /// The count of what was skipped comes back so the UI can say so instead of
  /// quietly producing a smaller dinner.
  Future<({String? id, int added, int skipped})> fromMealItems({
    required String name,
    required List<MealItem> items,
    int servings = 1,
  }) async {
    final usable = items.where((i) => i.foodId != null).toList();
    if (usable.isEmpty) {
      return (id: null, added: 0, skipped: items.length);
    }

    final id = await create(name: name, servings: servings);
    for (final item in usable) {
      await addIngredient(
        recipeId: id,
        foodId: item.foodId!,
        quantityG: item.quantityG,
      );
    }
    return (id: id, added: usable.length, skipped: items.length - usable.length);
  }

  /// Bumps `last_used_at`, which is what makes the list order useful.
  Future<void> touch(String id) =>
      (_db.update(_db.recipes)..where((r) => r.id.equals(id))).write(
        RecipesCompanion(
          lastUsedAt: Value(nowUtc()),
          updatedAt: Value(nowUtc()),
        ),
      );

  Future<int> _nextPosition(String recipeId) async {
    final rows = await (_db.select(_db.recipeItems)
          ..where((i) => i.recipeId.equals(recipeId))
          ..where((i) => i.deletedAt.isNull()))
        .get();
    return rows.isEmpty
        ? 0
        : rows.map((i) => i.position).reduce((a, b) => a > b ? a : b) + 1;
  }

  Future<int> _nextMealPosition(String mealId) async {
    final rows = await (_db.select(_db.mealItems)
          ..where((i) => i.mealId.equals(mealId))
          ..where((i) => i.deletedAt.isNull()))
        .get();
    return rows.isEmpty
        ? 0
        : rows.map((i) => i.position).reduce((a, b) => a > b ? a : b) + 1;
  }
}

final recipesRepositoryProvider = Provider<RecipesRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('RecipesRepository used while signed out');
  }
  return RecipesRepository(ref.watch(appDatabaseProvider), user.id);
});

final recipesProvider = StreamProvider<List<RecipeDetail>>(
  (ref) => ref.watch(recipesRepositoryProvider).watchRecipes(),
);

final recipeProvider = StreamProvider.family<RecipeDetail?, String>(
  (ref, id) => ref.watch(recipesRepositoryProvider).watchRecipe(id),
);

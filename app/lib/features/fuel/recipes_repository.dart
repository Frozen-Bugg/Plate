import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';
import 'meals_repository.dart';

/// One ingredient, with the food it points at.
///
/// The food travels with the item because every number on a favourite is
/// derived from it. `recipe_items.food_id` is NOT NULL in the schema, so an
/// ingredient always has one — but it can be soft-deleted out from under a
/// favourite, which is why [food] is nullable here.
class Ingredient {
  const Ingredient({required this.item, required this.food});

  final RecipeItem item;
  final Food? food;

  String get id => item.id;
  double get quantityG => item.quantityG;
  String get name => food?.name ?? 'Deleted food';

  /// What this much of it contains. Zero for a missing food rather than a
  /// guess: a favourite that quietly under-counts is worse than one that
  /// shows a gap.
  Nutrition get nutrition =>
      food == null ? _nothing : nutritionFor(food!, quantityG);
}

const _nothing = (kcal: 0.0, proteinG: 0.0, carbG: 0.0, fatG: 0.0, fibreG: 0.0);

/// A saved favourite and everything in it — a named group of foods, logged
/// again exactly as fast as it was said the first time.
///
/// Macros are computed from the food rows every time rather than stored,
/// same as anywhere else a food's own numbers are read live rather than
/// copied — a correction made to a food should show up here too.
class RecipeDetail {
  const RecipeDetail({required this.recipe, required this.ingredients});

  final Recipe recipe;
  final List<Ingredient> ingredients;

  String get id => recipe.id;
  String get name => recipe.name;

  /// What the whole thing contains, added up from its ingredients.
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

  bool get isEmpty => ingredients.isEmpty;
}

/// Favourites: named groups of foods, saved from a meal already logged and
/// quick-logged again from favorite_log_sheet.dart — the exception to
/// "nothing but the AI text box logs food", earned by being logged once
/// through it already.
class RecipesRepository {
  RecipesRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  /// Every favourite with its ingredients, most recently used first.
  ///
  /// One watched three-way join rather than a query per favourite. Drift
  /// re-emits when any of the three tables changes, so a food edited in one
  /// screen moves every favourite that uses it without anything having to
  /// invalidate anything.
  Stream<List<RecipeDetail>> watchAll() {
    final recipes = _db.recipes;
    final items = _db.recipeItems;
    final foods = _db.foods;

    final query =
        _db.select(recipes).join([
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
            OrderingTerm.desc(recipes.lastUsedAt),
            OrderingTerm.desc(recipes.createdAt),
            OrderingTerm.asc(items.position),
          ]);

    return query.watch().map(_group);
  }

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
        RecipeDetail(recipe: heads[id]!, ingredients: parts[id] ?? const []),
    ];
  }

  Future<String> _create(String name) async {
    // Views do not support RETURNING, so the id is generated here.
    final id = uuid.v7();
    await _db
        .into(_db.recipes)
        .insert(
          RecipesCompanion.insert(
            id: Value(id),
            userId: _userId,
            name: name,
            favourite: const Value(false),
          ),
        );
    return id;
  }

  Future<void> _addIngredient({
    required String recipeId,
    required String foodId,
    required double quantityG,
    required int position,
  }) => _db
      .into(_db.recipeItems)
      .insert(
        RecipeItemsCompanion.insert(
          id: Value(uuid.v7()),
          userId: _userId,
          recipeId: recipeId,
          foodId: foodId,
          quantityG: quantityG,
          position: Value(position),
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
        .write(
          RecipeItemsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
        );
    await (_db.update(_db.recipes)..where((r) => r.id.equals(id))).write(
      RecipesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  /// Turns a meal that was already logged into a reusable favourite.
  ///
  /// The cheapest useful thing in the whole feature: the favourites worth
  /// having are the meals already eaten, and this asks for a name rather
  /// than a form.
  ///
  /// Only items that came from a food can be carried over — `recipe_items`
  /// requires a `food_id`, and an item logged from another favourite has
  /// none. The count of what was skipped comes back so the UI can say so
  /// instead of quietly saving a smaller meal than the one on screen.
  Future<({String? id, int added, int skipped})> fromMealItems({
    required String name,
    required List<MealItem> items,
  }) async {
    final usable = items.where((i) => i.foodId != null).toList();
    if (usable.isEmpty) {
      return (id: null, added: 0, skipped: items.length);
    }

    final id = await _create(name);
    for (final (position, item) in usable.indexed) {
      await _addIngredient(
        recipeId: id,
        foodId: item.foodId!,
        quantityG: item.quantityG,
        position: position,
      );
    }
    return (
      id: id,
      added: usable.length,
      skipped: items.length - usable.length,
    );
  }

  /// Logs each ingredient of a favourite as its own item, at whatever amount
  /// [gramsByIngredientId] gives it — not necessarily the amount it was
  /// saved with. Mirrors how the AI logger writes food: one row per food,
  /// not one row for "a serving of the favourite".
  Future<void> logEachIngredient(
    RecipeDetail favourite, {
    required Map<String, double> gramsByIngredientId,
    required String slot,
    required String day,
  }) async {
    final meals = MealsRepository(_db, _userId);
    for (final ingredient in favourite.ingredients) {
      final food = ingredient.food;
      if (food == null) continue;
      final grams = gramsByIngredientId[ingredient.id] ?? ingredient.quantityG;
      if (grams <= 0) continue;
      await meals.logFood(
        food: food,
        quantityG: grams,
        slot: slot,
        day: day,
        source: 'recipe',
      );
    }
    await touch(favourite.id);
  }

  /// Bumps `last_used_at`, which is what makes the list order useful.
  Future<void> touch(String id) =>
      (_db.update(_db.recipes)..where((r) => r.id.equals(id))).write(
        RecipesCompanion(
          lastUsedAt: Value(nowUtc()),
          updatedAt: Value(nowUtc()),
        ),
      );
}

final recipesRepositoryProvider = Provider<RecipesRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('RecipesRepository used while signed out');
  }
  return RecipesRepository(ref.watch(appDatabaseProvider), user.id);
});

final favoritesProvider = StreamProvider<List<RecipeDetail>>(
  (ref) => ref.watch(recipesRepositoryProvider).watchAll(),
);

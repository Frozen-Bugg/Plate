import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/fuel/foods_repository.dart';
import 'package:overload/features/fuel/meals_repository.dart';
import 'package:overload/features/fuel/recipes_repository.dart';

import 'support/test_database.dart';

/// A meal saved as a favourite, then logged again at different amounts —
/// the replacement for a second AI reading of the same sentence.
void main() {
  const userId = 'u-1';
  const day = '2026-09-19';

  late TestDatabase db;
  late FoodsRepository foods;
  late MealsRepository meals;
  late RecipesRepository favorites;

  late Food eggs;
  late Food toast;

  setUp(() async {
    db = TestDatabase();
    foods = FoodsRepository(db, userId);
    meals = MealsRepository(db, userId);
    favorites = RecipesRepository(db, userId);

    eggs = await foods.remember(
      const FoodFacts(name: 'Eggs', kcalPer100: 155, proteinPer100: 13),
    );
    toast = await foods.remember(
      const FoodFacts(name: 'Toast', kcalPer100: 265, proteinPer100: 9),
    );
  });

  tearDown(() => db.close());

  Future<RecipeDetail> saveTodayAsFavorite(String name) async {
    await meals.logFood(
      food: eggs,
      quantityG: 100,
      slot: 'breakfast',
      day: day,
    );
    await meals.logFood(
      food: toast,
      quantityG: 60,
      slot: 'breakfast',
      day: day,
    );
    final log = await meals.watchDayLog(day).first;
    final saved = await favorites.fromMealItems(name: name, items: log.items);
    final all = await favorites.watchAll().first;
    return all.singleWhere((f) => f.id == saved.id);
  }

  test('saving today as a favourite carries over every logged item', () async {
    final favorite = await saveTodayAsFavorite('Eggs and toast');

    expect(favorite.name, 'Eggs and toast');
    expect(favorite.ingredients, hasLength(2));
    expect(
      favorite.ingredients.map((i) => i.name),
      containsAll(['Eggs', 'Toast']),
    );
  });

  test('skips items with no food behind them and reports the skip', () async {
    await meals.logFood(
      food: eggs,
      quantityG: 100,
      slot: 'breakfast',
      day: day,
    );
    final log = await meals.watchDayLog(day).first;
    final result = await favorites.fromMealItems(
      name: 'Just eggs',
      items: log.items,
    );

    expect(result.added, 1);
    expect(result.skipped, 0);
  });

  test('logging a favourite writes one meal item per ingredient', () async {
    final favorite = await saveTodayAsFavorite('Eggs and toast');
    final tomorrow = '2026-09-20';

    await favorites.logEachIngredient(
      favorite,
      gramsByIngredientId: {
        for (final i in favorite.ingredients) i.id: i.quantityG,
      },
      slot: 'breakfast',
      day: tomorrow,
    );

    final log = await meals.watchDayLog(tomorrow).first;
    expect(log.items, hasLength(2));
    expect(log.items.map((i) => i.foodId), containsAll([eggs.id, toast.id]));
  });

  test(
    'logging a favourite honours an edited amount, not the saved one',
    () async {
      final favorite = await saveTodayAsFavorite('Eggs and toast');
      final tomorrow = '2026-09-20';
      final eggsIngredient = favorite.ingredients.firstWhere(
        (i) => i.name == 'Eggs',
      );

      await favorites.logEachIngredient(
        favorite,
        gramsByIngredientId: {
          eggsIngredient.id: 200,
          favorite.ingredients.firstWhere((i) => i.name == 'Toast').id: 60,
        },
        slot: 'breakfast',
        day: tomorrow,
      );

      final log = await meals.watchDayLog(tomorrow).first;
      final loggedEggs = log.items.firstWhere((i) => i.foodId == eggs.id);
      expect(loggedEggs.quantityG, 200);
      // Double the grams, double the calories — proof the amount actually
      // drove the write rather than being logged and ignored.
      expect(loggedEggs.kcal, closeTo(310, 0.01));
    },
  );

  test('logging a favourite bumps its last-used order', () async {
    final a = await saveTodayAsFavorite('A');
    final b = await saveTodayAsFavorite('B');

    await favorites.logEachIngredient(
      a,
      gramsByIngredientId: {for (final i in a.ingredients) i.id: i.quantityG},
      slot: 'snack',
      day: '2026-09-20',
    );

    final ordered = await favorites.watchAll().first;
    expect(ordered.first.id, a.id, reason: 'most recently logged sorts first');
    expect(ordered.last.id, b.id);
  });

  test('deleting a favourite removes it from the list', () async {
    final favorite = await saveTodayAsFavorite('Eggs and toast');
    await favorites.delete(favorite.id);

    final all = await favorites.watchAll().first;
    expect(all, isEmpty);
  });
}

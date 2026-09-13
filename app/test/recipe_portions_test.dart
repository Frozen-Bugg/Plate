import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/fuel/recipes_repository.dart';

/// Portioning a cooked dish.
///
/// The arithmetic docs/MEAL-PLANNING.md §6 makes a claim about: macros come
/// from the raw ingredients, portions come from the cooked weight. Get it wrong
/// and every prepped lunch is wrong by however much water the rice took on —
/// silently, and in the direction of under-counting, which is the direction
/// that ruins a cut.

final _epoch = DateTime.utc(2026, 9, 14);

Food _food(String name, {required double kcal, double protein = 0}) => Food(
      id: name,
      createdAt: _epoch,
      updatedAt: _epoch,
      userId: 'u',
      name: name,
      source: 'custom',
      basis: 'g',
      kcalPer100: kcal,
      proteinPer100: protein,
      carbPer100: 0,
      fatPer100: 0,
      favourite: false,
    );

Ingredient _ingredient(Food food, double grams) => Ingredient(
      item: RecipeItem(
        id: '${food.id}-item',
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        recipeId: 'r',
        foodId: food.id,
        position: 0,
        quantityG: grams,
      ),
      food: food,
    );

RecipeDetail _recipe({
  int servings = 4,
  double? totalWeightG,
  List<Ingredient> ingredients = const [],
}) =>
    RecipeDetail(
      recipe: Recipe(
        id: 'r',
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        name: 'Chicken rice bowl',
        servings: servings,
        totalWeightG: totalWeightG,
        favourite: false,
      ),
      ingredients: ingredients,
    );

void main() {
  // 300 g dry rice at 360 kcal/100 g = 1080 kcal, weighing 300 g raw and
  // 900 g cooked.
  final rice = _food('rice', kcal: 360);
  final chicken = _food('chicken', kcal: 165, protein: 31);

  test('totals come from the ingredients, whatever the dish weighs', () {
    final raw = _recipe(ingredients: [_ingredient(rice, 300)]);
    final cooked = _recipe(
      ingredients: [_ingredient(rice, 300)],
      totalWeightG: 900,
    );

    // Water has no calories. The pot weighs three times as much and contains
    // exactly the same food.
    expect(raw.total.kcal, closeTo(1080, 0.01));
    expect(cooked.total.kcal, closeTo(1080, 0.01));
  });

  test('a portion is measured out of the cooked weight', () {
    final cooked = _recipe(
      servings: 4,
      ingredients: [_ingredient(rice, 300)],
      totalWeightG: 900,
    );

    expect(cooked.servingWeightG, closeTo(225, 0.01));
    // A quarter of the pot is a quarter of the calories, however heavy it is.
    expect(cooked.nutritionForGrams(225).kcal, closeTo(270, 0.01));
    expect(cooked.perServing.kcal, closeTo(270, 0.01));
  });

  test('weighing the tub beats counting servings', () {
    // Nobody portions a pot into four identical tubs. Logging the 260 g that
    // actually went in the box has to be right too.
    final cooked = _recipe(
      ingredients: [_ingredient(rice, 300)],
      totalWeightG: 900,
    );
    expect(cooked.nutritionForGrams(260).kcal, closeTo(312, 0.01));
  });

  test('an unweighed recipe portions by its raw weight', () {
    // No measured yield, so the pot is assumed to weigh what went into it.
    // Wrong for anything with water in it, which is why isWeighed exists for
    // the UI to nag about — but it is the only honest guess available, and it
    // keeps per-serving right even when per-100g is not.
    final guessed = _recipe(
      servings: 4,
      ingredients: [_ingredient(rice, 300), _ingredient(chicken, 500)],
    );

    expect(guessed.isWeighed, isFalse);
    expect(guessed.weightG, closeTo(800, 0.01));
    expect(guessed.servingWeightG, closeTo(200, 0.01));
    // 1080 + 825 = 1905 kcal over four servings.
    expect(guessed.perServing.kcal, closeTo(476.25, 0.01));
    expect(guessed.perServing.proteinG, closeTo(38.75, 0.01));
  });

  test('a recipe with nothing in it contains nothing, and does not divide by zero', () {
    final empty = _recipe(ingredients: const []);
    expect(empty.isEmpty, isTrue);
    expect(empty.weightG, 0);
    expect(empty.total.kcal, 0);
    expect(empty.nutritionForGrams(200).kcal, 0);
    expect(empty.perServing.kcal, 0);
  });

  test('a deleted food leaves a hole rather than a guess', () {
    // recipe_items.food_id is NOT NULL, but the food it points at can be soft
    // deleted. Scaling the rest to cover the gap would invent calories.
    final orphaned = Ingredient(
      item: RecipeItem(
        id: 'gone-item',
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        recipeId: 'r',
        foodId: 'gone',
        position: 1,
        quantityG: 200,
      ),
      food: null,
    );

    final holed = _recipe(
      servings: 1,
      ingredients: [_ingredient(rice, 300), orphaned],
    );

    expect(holed.total.kcal, closeTo(1080, 0.01));
    expect(holed.ingredients.last.name, 'Deleted food');
    // The weight still counts it, so a portion of the pot is not overstated.
    expect(holed.rawWeightG, closeTo(500, 0.01));
  });

  test('servings defaults to one rather than dividing by null', () {
    final unset = RecipeDetail(
      recipe: Recipe(
        id: 'r',
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        name: 'Scrambled eggs',
        favourite: false,
      ),
      ingredients: [_ingredient(chicken, 100)],
    );

    expect(unset.servings, 1);
    expect(unset.perServing.kcal, closeTo(165, 0.01));
  });
}

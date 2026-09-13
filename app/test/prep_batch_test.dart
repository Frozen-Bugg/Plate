import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/day.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/fuel/prep_repository.dart';
import 'package:overload/features/fuel/recipes_repository.dart';

/// What is left of a cook.
///
/// Nothing counts down: servings remaining is arithmetic over the portions
/// logged against the batch. That is what lets two phones log lunch at the same
/// time without inventing a third portion, and it is the part worth pinning.

final _epoch = DateTime.utc(2026, 9, 14);

Food _rice() => Food(
      id: 'rice',
      createdAt: _epoch,
      updatedAt: _epoch,
      userId: 'u',
      name: 'White rice, dry',
      source: 'custom',
      basis: 'g',
      kcalPer100: 360,
      proteinPer100: 7,
      carbPer100: 0,
      fatPer100: 0,
      favourite: false,
    );

/// 300 g of dry rice: 1080 kcal, 300 g raw, 900 g out of the pan.
RecipeDetail _recipe({double? totalWeightG = 900, int servings = 4}) =>
    RecipeDetail(
      recipe: Recipe(
        id: 'r',
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        name: 'Rice',
        servings: servings,
        totalWeightG: totalWeightG,
        favourite: false,
      ),
      ingredients: [
        Ingredient(
          item: RecipeItem(
            id: 'i',
            createdAt: _epoch,
            updatedAt: _epoch,
            userId: 'u',
            recipeId: 'r',
            foodId: 'rice',
            position: 0,
            quantityG: 300,
          ),
          food: _rice(),
        ),
      ],
    );

Batch _batch({
  double gramsEaten = 0,
  double? cookedWeightG = 900,
  int servingsMade = 4,
  String? useBy,
  RecipeDetail? recipe,
}) =>
    Batch(
      batch: PrepBatch(
        id: 'b',
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        recipeId: 'r',
        cookedOn: '2026-09-14',
        servingsMade: servingsMade,
        cookedWeightG: cookedWeightG,
        useBy: useBy,
      ),
      recipe: recipe ?? _recipe(),
      gramsEaten: gramsEaten,
    );

void main() {
  test('an untouched cook is all there', () {
    final batch = _batch();
    expect(batch.servingsLeft, closeTo(4, 0.001));
    expect(batch.gramsLeft, closeTo(900, 0.001));
    expect(batch.isFinished, isFalse);
  });

  test('one portion of four leaves three', () {
    final batch = _batch(gramsEaten: 225);
    expect(batch.servingsLeft, closeTo(3, 0.001));
    expect(batch.gramsLeft, closeTo(675, 0.001));
  });

  test('portions are fractional, because tubs are not identical', () {
    // 260 g out of a 900 g pot that was meant to be four 225 g servings.
    final batch = _batch(gramsEaten: 260);
    expect(batch.servingsLeft, closeTo(2.844, 0.01));
    expect(batch.isFinished, isFalse);
  });

  test('an empty tub is finished, and never goes negative', () {
    expect(_batch(gramsEaten: 900).isFinished, isTrue);
    // Eating more than was cooked is a mis-logged weight, not a debt.
    final over = _batch(gramsEaten: 1200);
    expect(over.gramsLeft, 0);
    expect(over.servingsLeft, 0);
    expect(over.isFinished, isTrue);
  });

  test('a scraping left is finished', () {
    // 20 g of a 225 g serving is not lunch, and offering it as one is worse
    // than saying the batch is done.
    expect(_batch(gramsEaten: 880).isFinished, isTrue);
  });

  test('macros come from the ingredients, portions from the cooked weight', () {
    final batch = _batch();
    expect(batch.servingWeightG, closeTo(225, 0.001));
    expect(batch.perServing.kcal, closeTo(270, 0.01));
    expect(batch.nutritionForGrams(260).kcal, closeTo(312, 0.01));
  });

  test('an unweighed cook falls back to the recipe, and says so', () {
    final batch = _batch(cookedWeightG: null);
    expect(batch.isWeighed, isFalse);
    expect(batch.weightG, closeTo(900, 0.001));

    // And with no measured yield anywhere, the raw weight is the last resort.
    final guessing = _batch(
      cookedWeightG: null,
      recipe: _recipe(totalWeightG: null),
    );
    expect(guessing.weightG, closeTo(300, 0.001));
  });

  test('the batch beats the recipe on weight, because it is this pot', () {
    // Cooked down twenty minutes longer: same food, less water.
    final batch = _batch(cookedWeightG: 780);
    expect(batch.weightG, closeTo(780, 0.001));
    expect(batch.servingWeightG, closeTo(195, 0.001));
    // Still 1080 kcal in the pot, so a quarter of it is still 270.
    expect(batch.perServing.kcal, closeTo(270, 0.01));
  });

  test('food about to go off is worth saying something about', () {
    final today = dayKey();
    final tomorrow = dayKey(parseDayKey(today).add(const Duration(days: 1)));
    final nextWeek = dayKey(parseDayKey(today).add(const Duration(days: 7)));
    final yesterday =
        dayKey(parseDayKey(today).subtract(const Duration(days: 1)));

    expect(_batch(useBy: nextWeek).needsEating, isFalse);
    expect(_batch(useBy: tomorrow).needsEating, isTrue);
    expect(_batch(useBy: today).needsEating, isTrue);
    expect(_batch(useBy: yesterday).isPastUseBy, isTrue);

    // An empty tub going off is not a problem anyone needs telling about.
    expect(_batch(useBy: tomorrow, gramsEaten: 900).needsEating, isFalse);
    // Nor is a batch with no use-by set.
    expect(_batch().needsEating, isFalse);
  });

  test('a deleted recipe leaves the batch readable rather than crashing', () {
    final orphan = Batch(
      batch: PrepBatch(
        id: 'b',
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        recipeId: 'gone',
        cookedOn: '2026-09-14',
        servingsMade: 4,
      ),
      recipe: null,
      gramsEaten: 0,
    );

    expect(orphan.name, 'Deleted recipe');
    expect(orphan.weightG, 0);
    expect(orphan.perServing.kcal, 0);
    expect(orphan.servingsLeft, 0);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/fuel/recipes_repository.dart';
import 'package:overload/features/fuel/recipes_screen.dart';

/// That the recipe screens render what they are given.
///
/// The providers are overridden rather than the database faked, so this needs
/// no device and no sign-in — which matters, because the alternative is
/// checking a screenshot on a phone that is not always plugged in.

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

RecipeDetail _recipe({
  String id = 'r',
  String name = 'Chicken rice bowl',
  int servings = 4,
  double? totalWeightG = 1330,
  bool favourite = false,
  bool empty = false,
}) =>
    RecipeDetail(
      recipe: Recipe(
        id: id,
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        name: name,
        servings: servings,
        totalWeightG: totalWeightG,
        favourite: favourite,
      ),
      ingredients: empty
          ? const []
          : [
              Ingredient(
                item: RecipeItem(
                  id: '$id-rice',
                  createdAt: _epoch,
                  updatedAt: _epoch,
                  userId: 'u',
                  recipeId: id,
                  foodId: 'rice',
                  position: 0,
                  quantityG: 300,
                ),
                food: _food('White rice, dry', kcal: 360),
              ),
              Ingredient(
                item: RecipeItem(
                  id: '$id-chicken',
                  createdAt: _epoch,
                  updatedAt: _epoch,
                  userId: 'u',
                  recipeId: id,
                  foodId: 'chicken',
                  position: 1,
                  quantityG: 600,
                ),
                food: _food('Chicken breast', kcal: 165, protein: 31),
              ),
            ],
    );

Widget _app(Widget home, List<RecipeDetail> recipes) => ProviderScope(
      overrides: [
        recipesProvider.overrideWith((ref) => Stream.value(recipes)),
        recipeProvider.overrideWith(
          (ref, id) => Stream.value(
            recipes.where((r) => r.id == id).firstOrNull,
          ),
        ),
      ],
      child: MaterialApp(home: home),
    );

void main() {
  testWidgets('an empty list explains the quickest way to fill it', (t) async {
    await t.pumpWidget(_app(const RecipesScreen(), const []));
    await t.pump();

    expect(find.text('Nothing saved yet'), findsOne);
    // The advice that matters: the recipes worth having are already logged.
    expect(find.textContaining('day log'), findsOne);
  });

  testWidgets('a recipe is listed by what one serving costs', (t) async {
    await t.pumpWidget(_app(const RecipesScreen(), [_recipe()]));
    await t.pump();

    expect(find.text('Chicken rice bowl'), findsOne);
    // 1080 kcal of rice + 990 of chicken = 2070, over four servings.
    expect(find.textContaining('518 kcal a serving'), findsOne);
    expect(find.textContaining('P 47'), findsOne);
  });

  testWidgets('no search field for a list you can see all of', (t) async {
    await t.pumpWidget(_app(const RecipesScreen(), [_recipe()]));
    await t.pump();
    expect(find.text('Search recipes'), findsNothing);
  });

  testWidgets('a search field once there are enough to lose one in', (t) async {
    await t.pumpWidget(_app(
      const RecipesScreen(),
      [for (var i = 0; i < 7; i++) _recipe(id: 'r$i', name: 'Recipe $i')],
    ));
    await t.pump();
    expect(find.text('Search recipes'), findsOne);
  });

  testWidgets('the detail leads with a serving and says it was weighed',
      (t) async {
    await t.pumpWidget(_app(const RecipeScreen(id: 'r'), [_recipe()]));
    await t.pump();

    expect(find.text('518'), findsOne);
    expect(find.text('kcal a serving'), findsOne);
    // 1330 g cooked over 4 servings, against 900 g of raw ingredients.
    expect(find.textContaining('Cooked weight 1330 g'), findsOne);
    expect(find.textContaining('raw 900 g'), findsOne);
  });

  testWidgets('an unweighed recipe says which weight it is portioning by',
      (t) async {
    await t.pumpWidget(
      _app(const RecipeScreen(id: 'r'), [_recipe(totalWeightG: null)]),
    );
    await t.pump();

    // The nudge, not an error: portioning by raw weight is the only honest
    // guess, and it is wrong by however much water the rice took on.
    expect(find.textContaining('Not weighed'), findsOne);
    expect(find.textContaining('900 g'), findsOne);
  });

  testWidgets('an empty recipe offers no portion to log', (t) async {
    await t.pumpWidget(
      _app(const RecipeScreen(id: 'r'), [_recipe(empty: true)]),
    );
    await t.pump();

    expect(find.text('Log a portion'), findsNothing);
    expect(find.textContaining('Nothing in it yet'), findsOne);
  });
}

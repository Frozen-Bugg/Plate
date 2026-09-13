import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/day.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/fuel/prep_repository.dart';
import 'package:overload/features/fuel/prep_screen.dart';
import 'package:overload/features/fuel/recipes_repository.dart';

/// The fridge on the day log.
///
/// Prep only pays for itself if eating it is easier than not, so this is the
/// card that decides whether the feature gets used. Providers are overridden,
/// so no device and no sign-in.

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

RecipeDetail _chilli() => RecipeDetail(
      recipe: Recipe(
        id: 'r',
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        name: 'Beef chilli',
        servings: 4,
        totalWeightG: 900,
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

BatchRow _row({
  double gramsEaten = 0,
  String? useBy,
  String id = 'b',
  String cookedOn = '2026-09-14',
}) =>
    (
      batch: PrepBatch(
        id: id,
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        recipeId: 'r',
        cookedOn: cookedOn,
        servingsMade: 4,
        cookedWeightG: 900,
        useBy: useBy,
      ),
      gramsEaten: gramsEaten,
    );

Widget _app(List<BatchRow> rows) => ProviderScope(
      overrides: [
        recipesProvider.overrideWith((ref) => Stream.value([_chilli()])),
        batchRowsProvider.overrideWith((ref) => Stream.value(rows)),
      ],
      child: MaterialApp(
        home: Scaffold(body: FridgeCard(day: dayKey())),
      ),
    );

String _inDays(int days) =>
    dayKey(parseDayKey(dayKey()).add(Duration(days: days)));

void main() {
  testWidgets('nothing cooked shows nothing at all', (t) async {
    await t.pumpWidget(_app(const []));
    await t.pumpAndSettle();

    // An empty card teaching a feature is worse than no card.
    expect(find.text('IN THE FRIDGE'), findsNothing);
  });

  testWidgets('a cook shows what is left and what it costs', (t) async {
    await t.pumpWidget(_app([_row()]));
    await t.pumpAndSettle();

    expect(find.text('IN THE FRIDGE'), findsOne);
    expect(find.text('Beef chilli'), findsOne);
    // 900 g in four portions, 1080 kcal of rice in the pot.
    expect(find.textContaining('4 servings left'), findsOne);
    expect(find.textContaining('270 kcal each'), findsOne);
    expect(find.text('Eat'), findsOne);
  });

  // One pumpWidget each: a second one in the same test reuses the element
  // tree and the new overrides never take.
  testWidgets('three portions left reads as three', (t) async {
    await t.pumpWidget(_app([_row(gramsEaten: 225)]));
    await t.pumpAndSettle();
    expect(find.textContaining('3 servings left'), findsOne);
  });

  testWidgets('one portion left is a serving, not 1.0 servings', (t) async {
    await t.pumpWidget(_app([_row(gramsEaten: 675)]));
    await t.pumpAndSettle();
    expect(find.textContaining('1 serving left'), findsOne);
  });

  testWidgets('a scraping is half a serving rather than 0.49', (t) async {
    await t.pumpWidget(_app([_row(gramsEaten: 790)]));
    await t.pumpAndSettle();
    expect(find.textContaining('half a serving left'), findsOne);
  });

  testWidgets('an empty tub leaves the fridge', (t) async {
    await t.pumpWidget(_app([_row(gramsEaten: 900)]));
    await t.pumpAndSettle();
    expect(find.text('Beef chilli'), findsNothing);
  });

  testWidgets('food past its use-by is not offered', (t) async {
    await t.pumpWidget(_app([_row(useBy: _inDays(-1))]));
    await t.pumpAndSettle();
    expect(find.text('Beef chilli'), findsNothing);
  });

  testWidgets('food going tomorrow says tomorrow', (t) async {
    await t.pumpWidget(_app([_row(useBy: _inDays(1))]));
    await t.pumpAndSettle();
    expect(find.textContaining('eat by tomorrow'), findsOne);
  });

  testWidgets('food going today says today', (t) async {
    await t.pumpWidget(_app([_row(useBy: _inDays(0))]));
    await t.pumpAndSettle();
    expect(find.textContaining('eat today'), findsOne);
  });

  testWidgets('food with a week in it does not nag', (t) async {
    await t.pumpWidget(_app([_row(useBy: _inDays(4))]));
    await t.pumpAndSettle();
    expect(find.textContaining('4 days left'), findsOne);
  });

  testWidgets('what needs eating first comes first', (t) async {
    await t.pumpWidget(_app([
      _row(id: 'keeps', useBy: _inDays(5)),
      _row(id: 'urgent', useBy: _inDays(1)),
    ]));
    await t.pumpAndSettle();

    final rows = t.widgetList<Text>(find.textContaining('left')).toList();
    expect(rows.first.data, contains('eat by tomorrow'));
  });

  testWidgets('tapping Eat opens a portion sheet capped at what is left',
      (t) async {
    await t.pumpWidget(_app([_row(gramsEaten: 675)]));
    await t.pumpAndSettle();

    await t.tap(find.text('Eat'));
    await t.pumpAndSettle();

    // 225 g left of 900 g, and the sheet says both.
    expect(find.textContaining('225 g left of 900 g'), findsOne);
    expect(find.text('All of it'), findsOne);
  });
}

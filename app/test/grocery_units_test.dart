import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/fuel/groceries_repository.dart';

/// How a shopping list reads.
///
/// A list in grams is a list written for a database. This is the bit that
/// decides whether it is usable in a shop, so it is worth pinning.

final _epoch = DateTime.utc(2026, 9, 14);

Food _food({double? servingG, String? servingLabel}) => Food(
      id: 'f',
      createdAt: _epoch,
      updatedAt: _epoch,
      userId: 'u',
      name: 'Eggs',
      source: 'custom',
      basis: 'g',
      kcalPer100: 155,
      proteinPer100: 13,
      carbPer100: 1,
      fatPer100: 11,
      servingG: servingG,
      servingLabel: servingLabel,
      favourite: false,
    );

GroceryLine _line({double? grams, Food? food, String name = 'Chicken breast'}) =>
    GroceryLine(
      item: GroceryItem(
        id: 'i',
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        listId: 'l',
        name: name,
        quantityG: grams,
        fromPlan: true,
        checked: false,
        position: 0,
      ),
      food: food,
    );

void main() {
  test('a kilo and a half is 1.5 kg, not 1500 g', () {
    expect(_line(grams: 1500).amount, '1.5 kg');
    expect(_line(grams: 1340).amount, '1.3 kg');
    // Past ten it is the decimal that stops being useful.
    expect(_line(grams: 12400).amount, '12 kg');
  });

  test('under a kilo stays in grams, because that is how it is sold', () {
    expect(_line(grams: 600).amount, '600 g');
    expect(_line(grams: 30).amount, '30 g');
    expect(_line(grams: 999).amount, '999 g');
  });

  test('something sold by the piece is counted', () {
    final eggs = _food(servingG: 60, servingLabel: 'egg');
    expect(_line(grams: 720, food: eggs).amount, '12 × egg');
    expect(_line(grams: 360, food: eggs).amount, '6 × egg');
  });

  test('a count is only used when it is nearly a whole number of them', () {
    // 500 g of 60 g eggs is 8.3 eggs. "8 eggs" would be wrong by a third of
    // one, and the weight is the honest answer.
    final eggs = _food(servingG: 60, servingLabel: 'egg');
    expect(_line(grams: 500, food: eggs).amount, '500 g');
    // Just off a whole number is still that whole number.
    expect(_line(grams: 725, food: eggs).amount, '12 × egg');
  });

  test('less than one serving is a weight, not a fraction of a piece', () {
    final eggs = _food(servingG: 60, servingLabel: 'egg');
    expect(_line(grams: 30, food: eggs).amount, '30 g');
  });

  test('a piece with no label is just a number', () {
    expect(_line(grams: 240, food: _food(servingG: 60)).amount, '4');
  });

  test('a line with no amount shows nothing rather than zero', () {
    // Bin bags have no weight, and "0 g of bin bags" is worse than no number.
    expect(_line(name: 'Bin bags').amount, '');
    expect(_line(name: 'Bin bags', grams: 0).amount, '');
  });

  test('a list is done only when it has lines and none are left', () {
    GroceryLine ticked(bool checked) => GroceryLine(
          item: GroceryItem(
            id: 'i$checked',
            createdAt: _epoch,
            updatedAt: _epoch,
            userId: 'u',
            listId: 'l',
            name: 'Rice',
            fromPlan: true,
            checked: checked,
            position: 0,
          ),
          food: null,
        );

    final row = GroceryListRow(
      id: 'l',
      createdAt: _epoch,
      updatedAt: _epoch,
      userId: 'u',
      name: 'This week',
    );

    expect(GroceryList(list: row, lines: [ticked(true)]).isDone, isTrue);
    expect(GroceryList(list: row, lines: [ticked(false)]).left, 1);
    // An empty list is not a finished one.
    expect(GroceryList(list: row, lines: const []).isDone, isFalse);
  });
}

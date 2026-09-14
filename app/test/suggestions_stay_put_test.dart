import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/fuel/quick_add_service.dart';
import 'package:overload/features/fuel/recipes_repository.dart';
import 'package:overload/features/fuel/suggest_service.dart';

/// Suggestions are a thing you were given, not a fresh roll of the dice.
///
/// The sheet used to ask on every open, so glancing at the options and closing
/// it threw them away: reopening produced three different meals and no way back
/// to the one you had half-decided on.

class _FakeSuggest implements SuggestService {
  int calls = 0;
  String? lastNote;

  @override
  Future<Suggestions> suggest({required String day, String? note}) async {
    calls++;
    lastNote = note;
    return Suggestions(
      leftKcal: 1200,
      leftProteinG: 90,
      options: [
        Suggestion(
          name: 'Option $calls',
          kcal: 500,
          proteinG: 40,
          carbG: 40,
          fatG: 15,
          why: 'because',
        ),
      ],
    );
  }
}

ProviderContainer _container(_FakeSuggest fake) => ProviderContainer(
      overrides: [suggestServiceProvider.overrideWithValue(fake)],
    );

void main() {
  test('the second look shows what the first one did', () async {
    final fake = _FakeSuggest();
    final container = _container(fake);
    addTearDown(container.dispose);

    await container.read(suggestionsProvider.notifier).ensure(day: '2026-09-14');
    final first = container.read(suggestionsProvider).suggestions!.options.first;

    // Closing and reopening the sheet is another ensure() for the same day.
    await container.read(suggestionsProvider.notifier).ensure(day: '2026-09-14');
    final second =
        container.read(suggestionsProvider).suggestions!.options.first;

    expect(fake.calls, 1, reason: 'asked the coach again for no reason');
    expect(second.name, first.name);
  });

  test('the refresh button is what changes them', () async {
    final fake = _FakeSuggest();
    final container = _container(fake);
    addTearDown(container.dispose);

    await container.read(suggestionsProvider.notifier).ensure(day: '2026-09-14');
    await container
        .read(suggestionsProvider.notifier)
        .ensure(day: '2026-09-14', force: true);

    expect(fake.calls, 2);
    expect(
      container.read(suggestionsProvider).suggestions!.options.first.name,
      'Option 2',
    );
  });

  test('a new day is a new question', () async {
    final fake = _FakeSuggest();
    final container = _container(fake);
    addTearDown(container.dispose);

    await container.read(suggestionsProvider.notifier).ensure(day: '2026-09-14');
    await container.read(suggestionsProvider.notifier).ensure(day: '2026-09-15');

    // Yesterday's answer is about a day that has finished.
    expect(fake.calls, 2);
  });

  test('what you typed is passed along, and asks again', () async {
    final fake = _FakeSuggest();
    final container = _container(fake);
    addTearDown(container.dispose);

    await container.read(suggestionsProvider.notifier).ensure(day: '2026-09-14');
    await container.read(suggestionsProvider.notifier).askWith(
          day: '2026-09-14',
          note: '  chicken and rice  ',
        );

    expect(fake.calls, 2);
    expect(fake.lastNote, 'chicken and rice');
  });

  test('the old options stay on screen while a refresh runs', () async {
    // A blank sheet mid-refresh loses the option somebody was reading.
    final fake = _FakeSuggest();
    final container = _container(fake);
    addTearDown(container.dispose);

    await container.read(suggestionsProvider.notifier).ensure(day: '2026-09-14');
    final refreshing = container
        .read(suggestionsProvider.notifier)
        .ensure(day: '2026-09-14', force: true);

    final mid = container.read(suggestionsProvider);
    expect(mid.asking, isTrue);
    expect(mid.suggestions?.options.first.name, 'Option 1');

    await refreshing;
  });

  _methodTests();

  test('a first open with nothing held does ask', () async {
    final fake = _FakeSuggest();
    final container = _container(fake);
    addTearDown(container.dispose);

    expect(container.read(suggestionsProvider).isEmpty, isTrue);
    await container.read(suggestionsProvider.notifier).ensure(day: '2026-09-14');
    expect(fake.calls, 1);
  });
}

/// The method, read back off a saved recipe.
final _epoch = DateTime.utc(2026, 9, 14);

RecipeDetail _recipe(String? method) => RecipeDetail(
      recipe: Recipe(
        id: 'r',
        createdAt: _epoch,
        updatedAt: _epoch,
        userId: 'u',
        name: 'Chicken rice bowl',
        servings: 4,
        method: method,
        favourite: false,
      ),
      ingredients: const [],
    );

void _methodTests() {
  test('a method is a step to a line', () {
    final recipe = _recipe('Rinse the rice.\nSimmer it 10 minutes.\nRest it.');
    expect(recipe.steps.length, 3);
    expect(recipe.steps.first, 'Rinse the rice.');
    expect(recipe.hasMethod, isTrue);
  });

  test('blank lines are not steps', () {
    final recipe = _recipe('Beat the eggs.\n\n   \nPour them in.\n');
    expect(recipe.steps, ['Beat the eggs.', 'Pour them in.']);
  });

  test('no method at all is not an empty step', () {
    expect(_recipe(null).steps, isEmpty);
    expect(_recipe(null).hasMethod, isFalse);
    expect(_recipe('').hasMethod, isFalse);
  });
}

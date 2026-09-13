import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/widgets/tab_scaffold.dart';
import '../../core/day.dart';
import '../../core/db/app_database.dart';
import 'add_food_sheet.dart';
import 'foods_repository.dart';
import 'macro_rings.dart';
import 'meals_repository.dart';
import 'groceries_repository.dart';
import 'groceries_screen.dart';
import 'prep_screen.dart';
import 'quick_add_sheet.dart';
import 'recipes_repository.dart';
import 'recipes_screen.dart';
import 'suggest_sheet.dart';
import 'targets_repository.dart';
import 'targets_screen.dart';

/// The day log: what was eaten, against what was meant to be.
class FuelScreen extends ConsumerWidget {
  const FuelScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final day = ref.watch(fuelDayProvider);
    final log = ref.watch(dayLogProvider(day)).value;
    final target = ref.watch(targetForDayProvider(day));
    final total = log?.total ?? DayLog.totalOf(const []);

    return TabScaffold(
      title: 'Fuel',
      actions: [
        const _ShoppingButton(),
        IconButton(
          tooltip: 'Recipes',
          icon: const Icon(Icons.menu_book_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RecipesScreen(day: day),
            ),
          ),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 148),
        children: [
          const _DayBar(),
          const SizedBox(height: 16),
          Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              // Tapping the rings goes to where the numbers came from, which is
              // the question anyone looking at them eventually asks.
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const TargetsScreen()),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    MacroRings(
                      kcal: total.kcal,
                      kcalTarget: target?.kcal.toDouble(),
                      proteinG: total.proteinG,
                      proteinTarget: target?.proteinG,
                      carbG: total.carbG,
                      carbTarget: target?.carbG,
                      fatG: total.fatG,
                      fatTarget: target?.fatG,
                    ),
                    if (target?.shifted ?? false) ...[
                      const SizedBox(height: 10),
                      _ShiftNote(target: target!),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (target == null) ...[
            const SizedBox(height: 12),
            const _NoTargetCard(),
          ],
          const SizedBox(height: 16),
          FridgeCard(day: day),
          for (final slot in mealSlots) _Slot(slot: slot, log: log),
        ],
      ),
      // Two ways in, because they suit different moments. Search is exact and
      // works offline; saying it is faster when you have just eaten four
      // things and do not want to look up any of them.
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'suggest',
            tooltip: 'What should I eat?',
            onPressed: () => showSuggestSheet(context, day: day),
            child: const Icon(Icons.lightbulb_outline),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.small(
            heroTag: 'quick-add',
            tooltip: 'Say or type a whole meal',
            onPressed: () => showQuickAddSheet(context, day: day),
            child: const Icon(Icons.mic_none),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'log-food',
            onPressed: () => showAddFoodSheet(context, day: day),
            icon: const Icon(Icons.add),
            label: const Text('Log food'),
          ),
        ],
      ),
    );
  }
}

/// The shopping list, with what is left to pick up on it.
///
/// Only shown once there is a list. A basket icon that always leads to an
/// empty screen is one nobody presses twice.
class _ShoppingButton extends ConsumerWidget {
  const _ShoppingButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(currentGroceryListProvider);
    if (list == null) return const SizedBox.shrink();

    return IconButton(
      tooltip: 'Shopping',
      icon: Badge(
        isLabelVisible: list.left > 0,
        label: Text('${list.left}'),
        child: const Icon(Icons.shopping_basket_outlined),
      ),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const GroceriesScreen()),
      ),
    );
  }
}

/// Why today's carbohydrate is not the same as yesterday's.
///
/// A target that silently differs by day is one nobody trusts. The weekly
/// total has not moved — this is the same food, put where the training is.
class _ShiftNote extends StatelessWidget {
  const _ShiftNote({required this.target});

  final DayTarget target;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final up = target.carbG > target.baseCarbG;
    final moved = (target.carbG - target.baseCarbG).abs().round();

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          up ? Icons.trending_up : Icons.trending_down,
          size: 14,
          color: muted,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            up
                ? 'Training day: $moved g more carbs, borrowed from rest days'
                : 'Rest day: $moved g fewer carbs, saved for training days',
            style: text.labelSmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// Which day is on screen, and a way to walk back through the week.
class _DayBar extends ConsumerWidget {
  const _DayBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final day = ref.watch(fuelDayProvider);
    final isToday = day == dayKey();
    final date = parseDayKey(day);

    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: () => ref.read(fuelDayProvider.notifier).step(-1),
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                isToday ? 'TODAY' : DateFormat('EEEE').format(date).toUpperCase(),
                style: text.labelSmall?.copyWith(color: muted, letterSpacing: 1),
              ),
              Text(DateFormat('d MMMM').format(date), style: text.titleMedium),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          // Tomorrow has not happened, and a food log that lets you fill it in
          // is a food log that lies to the engine reading it.
          onPressed:
              isToday ? null : () => ref.read(fuelDayProvider.notifier).step(1),
        ),
      ],
    );
  }
}

/// Says why the rings have nothing to measure against, and offers the fix.
class _NoTargetCard extends ConsumerWidget {
  const _NoTargetCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final tdee = ref.watch(tdeeProvider).value;
    final canEstimate = tdee != null && tdee.kcal > 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('No targets yet', style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              canEstimate
                  ? 'The engine can set them from your weight, your steps and '
                      'the phase you picked. They are a starting point and '
                      'every number is editable.'
                  : 'Targets need your height, age and sex to start from, and a '
                      'weigh-in. Add them in Settings and the engine will do '
                      'the rest.',
              style: text.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const TargetsScreen()),
              ),
              child: Text(canEstimate ? 'Set targets' : 'See what is missing'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One slot of the day — breakfast, lunch, dinner or snacks.
///
/// Always shown, even when empty. An empty lunch is information, and a day that
/// only shows what was logged hides what was not.
class _Slot extends ConsumerWidget {
  const _Slot({required this.slot, required this.log});

  final String slot;
  final DayLog? log;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final day = ref.watch(fuelDayProvider);
    final meal = log?.meals.where((m) => m.slot == slot).firstOrNull;
    final items = meal == null ? const <MealItem>[] : log!.itemsIn(meal.id);
    final total = DayLog.totalOf(items);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(_label(slot), style: text.titleSmall),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    items.isEmpty ? '—' : '${total.kcal.round()} kcal',
                    style: text.labelLarge?.copyWith(color: muted),
                  ),
                  _SlotMenu(slot: slot, day: day, items: items),
                ],
              ),
              onTap: () => showAddFoodSheet(context, day: day, slot: slot),
            ),
            for (final item in items) _Item(item: item),
          ],
        ),
      ),
    );
  }

  static String _label(String slot) => switch (slot) {
        'breakfast' => 'Breakfast',
        'lunch' => 'Lunch',
        'dinner' => 'Dinner',
        'snack' => 'Snacks',
        _ => slot,
      };
}

/// What else a meal slot can do: log a saved recipe, or become one.
///
/// "Save as a recipe" is here rather than anywhere cleverer because this is
/// where the information already is. The recipes worth keeping are the meals
/// already eaten, and asking for a name is the whole of the work.
class _SlotMenu extends ConsumerWidget {
  const _SlotMenu({required this.slot, required this.day, required this.items});

  final String slot;
  final String day;
  final List<MealItem> items;

  Future<void> _saveAsRecipe(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NameDialog(slot: slot),
    );
    if (name == null || !context.mounted) return;

    final saved = await ref.read(recipesRepositoryProvider).fromMealItems(
          name: name,
          items: items,
        );
    if (!context.mounted) return;

    // Items logged from another recipe have no food_id to carry over, and
    // recipe_items requires one. Saying so beats quietly saving a smaller
    // dinner than the one on screen.
    final messenger = ScaffoldMessenger.of(context);
    if (saved.id == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Nothing here can become an ingredient yet.'),
        ),
      );
      return;
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved.skipped == 0
              ? 'Saved "$name" · ${saved.added} ingredients'
              : 'Saved "$name" · ${saved.added} ingredients, '
                  '${saved.skipped} skipped',
        ),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RecipeScreen(id: saved.id!, day: day, slot: slot),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      tooltip: 'More',
      onSelected: (choice) async {
        switch (choice) {
          case 'recipe':
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RecipesScreen(day: day, slot: slot),
              ),
            );
          case 'save':
            await _saveAsRecipe(context, ref);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'recipe', child: Text('Log a recipe')),
        PopupMenuItem(
          value: 'save',
          enabled: items.isNotEmpty,
          child: const Text('Save as a recipe'),
        ),
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.slot});

  final String slot;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    Navigator.of(context).pop(value.isEmpty ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save as a recipe'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Name',
          hintText: 'Chicken rice bowl',
          helperText: 'The amounts come across as they were logged. Set the '
              'servings and the cooked weight afterwards.',
          helperMaxLines: 3,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _Item extends ConsumerWidget {
  const _Item({required this.item});

  final MealItem item;

  /// Correcting an amount, rather than deleting the row and logging it again.
  ///
  /// Weighing after cooking, or going back for more, is the ordinary case; the
  /// repository could already rescale an item's macros and nothing in the app
  /// could reach it.
  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final foodId = item.foodId;
    if (foodId == null) return;
    final food = await ref.read(foodsRepositoryProvider).byId(foodId);
    if (food == null || !context.mounted) return;

    final grams = await showQuantitySheet(
      context,
      food: food,
      initialGrams: item.quantityG,
      cta: 'Save',
    );
    if (grams == null) return;
    await ref.read(mealsRepositoryProvider).setQuantity(item, grams);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Dismissible(
      key: ValueKey(item.id),
      direction: DismissDirection.endToStart,
      background: ColoredBox(
        color: Theme.of(context).colorScheme.error,
        child: const Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.only(right: 20),
            child: Icon(Icons.delete_outline, color: Colors.white),
          ),
        ),
      ),
      onDismissed: (_) =>
          ref.read(mealsRepositoryProvider).deleteItem(item.id),
      child: ListTile(
        dense: true,
        onTap: item.foodId == null ? null : () => _edit(context, ref),
        // A provider rather than a future built here: a FutureBuilder handed a
        // fresh future on every rebuild restarts on every rebuild, and a day
        // with twenty items would flicker through all of them.
        title: Text(_name(ref)),
        subtitle: Text(
          '${item.quantityG.round()} g · '
          'P ${item.proteinG.round()} · '
          'C ${item.carbG.round()} · '
          'F ${item.fatG.round()}',
          style: text.labelSmall?.copyWith(color: muted),
        ),
        trailing: Text('${item.kcal.round()}', style: text.labelLarge),
      ),
    );
  }

  /// The food's name, or a neutral stand-in.
  ///
  /// The item carries its own macros, so it stays readable even when the food
  /// behind it has been taken off the list — which is the whole reason those
  /// numbers are stored rather than looked up.
  String _name(WidgetRef ref) {
    if (item.foodId case final id?) {
      return ref.watch(foodByIdProvider(id)).value?.name ?? 'Food';
    }
    if (item.recipeId case final id?) {
      // Was the literal word "Recipe" before there were any. The row keeps its
      // own macros either way, so a deleted recipe still reads sensibly.
      return ref.watch(recipeProvider(id)).value?.name ?? 'Recipe';
    }
    return 'Food';
  }
}

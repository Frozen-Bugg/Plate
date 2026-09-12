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
import 'targets_repository.dart';
import 'targets_screen.dart';

/// The day log: what was eaten, against what was meant to be.
class FuelScreen extends ConsumerWidget {
  const FuelScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final day = ref.watch(fuelDayProvider);
    final log = ref.watch(dayLogProvider(day)).value;
    final target = ref.watch(todayTargetProvider);
    final total = log?.total ?? DayLog.totalOf(const []);

    return TabScaffold(
      title: 'Fuel',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
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
                child: MacroRings(
                  kcal: total.kcal,
                  kcalTarget: target?.kcal.toDouble(),
                  proteinG: total.proteinG,
                  proteinTarget: target?.proteinG,
                  carbG: total.carbG,
                  carbTarget: target?.carbG,
                  fatG: total.fatG,
                  fatTarget: target?.fatG,
                ),
              ),
            ),
          ),
          if (target == null) ...[
            const SizedBox(height: 12),
            const _NoTargetCard(),
          ],
          const SizedBox(height: 16),
          for (final slot in mealSlots) _Slot(slot: slot, log: log),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showAddFoodSheet(context, day: day),
        icon: const Icon(Icons.add),
        label: const Text('Log food'),
      ),
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
              trailing: Text(
                items.isEmpty ? '—' : '${total.kcal.round()} kcal',
                style: text.labelLarge?.copyWith(color: muted),
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

class _Item extends ConsumerWidget {
  const _Item({required this.item});

  final MealItem item;

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
    if (item.recipeId != null) return 'Recipe';
    return 'Food';
  }
}

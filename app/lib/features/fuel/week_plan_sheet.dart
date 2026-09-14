import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import 'foods_repository.dart';
import 'groceries_repository.dart';
import 'prep_repository.dart';
import 'quick_add_service.dart';
import 'recipes_repository.dart';
import 'suggest_service.dart';

/// A week of cooking, and the shopping that follows from it.
///
/// Two or three cooks rather than twenty-one meals, reduced by what is already
/// in the fridge. Accepting it saves any new recipes and builds a grocery list
/// — it does **not** log any food. A plan is not a meal, and adaptive TDEE is
/// only worth having if it is built on what was actually eaten.
Future<void> showWeekPlanSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: const _WeekPlanSheet(),
    ),
  );
}

class _WeekPlanSheet extends ConsumerStatefulWidget {
  const _WeekPlanSheet();

  @override
  ConsumerState<_WeekPlanSheet> createState() => _WeekPlanSheetState();
}

class _WeekPlanSheetState extends ConsumerState<_WeekPlanSheet> {
  final _note = TextEditingController();
  PrepPlan? _plan;
  String? _error;
  var _asking = false;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    setState(() {
      _asking = true;
      _error = null;
    });
    try {
      final plan = await ref.read(draftServiceProvider).draftPlan(
            note: _note.text,
          );
      if (mounted) setState(() => _plan = plan);
    } on QuickAddError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'The coach could not answer.');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// Saves any new recipes and builds the shopping list.
  Future<void> _accept() async {
    final plan = _plan;
    if (plan == null || _saving) return;
    setState(() => _saving = true);

    final recipes = ref.read(recipesRepositoryProvider);
    final foods = ref.read(foodsRepositoryProvider);
    final saved = ref.read(recipesProvider).value ?? const <RecipeDetail>[];

    final wanted = <({String name, String? foodId, double grams})>[];

    for (final cook in plan.cooks) {
      if (cook.saved) {
        // Already on the shelf, with its ingredients and its own weights. The
        // shopping is scaled to how many batches of it the week wants.
        final recipe = saved
            .where((r) => r.name.toLowerCase() == cook.name.toLowerCase())
            .firstOrNull;
        if (recipe == null) continue;
        final batches =
            recipe.servings > 0 ? cook.servings / recipe.servings : 1;
        for (final ingredient in recipe.ingredients) {
          if (ingredient.food case final food?) {
            wanted.add((
              name: food.name,
              foodId: food.id,
              grams: ingredient.quantityG * batches,
            ));
          }
        }
        continue;
      }

      // A new dish: save it as a recipe so it can be cooked and logged, then
      // shop for it. Unmatched ingredients still go on the list — they have to
      // be bought whether or not the app knows their calories.
      final id = await recipes.create(name: cook.name, servings: cook.servings);

      // Anything the shelf cannot answer is priced by the coach, in one call
      // for the whole cook, and saved as an estimate. A recipe whose olive oil
      // counts as zero is a recipe that quietly under-reports every portion of
      // it — see docs/MEAL-PLANNING.md §3.
      final matched = <String, Food?>{};
      for (final ingredient in cook.ingredients) {
        matched[ingredient.name] = await foods.bestMatch(ingredient.name);
      }
      final unpriced = [
        for (final MapEntry(:key, :value) in matched.entries)
          if (value == null) key,
      ];
      if (unpriced.isNotEmpty) {
        try {
          final priced =
              await ref.read(draftServiceProvider).estimate(unpriced);
          for (final estimate in priced) {
            for (final name in unpriced) {
              if (name.trim().toLowerCase() ==
                  estimate.name.trim().toLowerCase()) {
                matched[name] = await foods.remember(estimate.facts);
              }
            }
          }
        } catch (_) {
          // The shopping still works; the recipe is short by whatever could
          // not be priced, and its screen says which.
        }
      }

      for (final ingredient in cook.ingredients) {
        final food = matched[ingredient.name];
        if (food != null) {
          await recipes.addIngredient(
            recipeId: id,
            foodId: food.id,
            quantityG: ingredient.grams,
          );
        }
        wanted.add((
          name: food?.name ?? ingredient.name,
          foodId: food?.id,
          grams: ingredient.grams,
        ));
      }
    }

    await ref.read(groceriesRepositoryProvider).build(wanted: wanted);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final onHand = ref.watch(prepOnHandProvider);

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Cook for the week', style: text.headlineSmall),
            const SizedBox(height: 4),
            Text(
              onHand.isEmpty
                  ? 'Two or three cooks, not twenty-one meals.'
                  : '${onHand.length} ${onHand.length == 1 ? 'batch' : 'batches'} '
                      'already in the fridge — the plan works around them.',
              style: text.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            Expanded(child: _body(context)),
            const SizedBox(height: 8),
            TextField(
              controller: _note,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: 'Anything to work around? "six lunches, no fish"',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _asking ? null : _ask,
                ),
              ),
              onSubmitted: (_) => _ask(),
            ),
            if (_plan?.cooks.isNotEmpty ?? false) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _saving ? null : _accept,
                icon: const Icon(Icons.shopping_basket_outlined),
                label: const Text('Save cooks and build a list'),
              ),
              const SizedBox(height: 2),
              Text(
                'Saves the recipes and the shopping. Nothing is logged as '
                'eaten until you eat it.',
                textAlign: TextAlign.center,
                style: text.labelSmall?.copyWith(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    if (_asking && _plan == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error case final error?) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _ask, child: const Text('Try again')),
          ],
        ),
      );
    }

    final cooks = _plan?.cooks ?? const <PlannedCook>[];
    if (cooks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _plan == null
                ? 'Nothing yet.'
                : 'Nothing to cook — the fridge covers the week. That is the '
                    'good outcome.',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: muted),
          ),
        ),
      );
    }

    return ListView(
      children: [
        for (final cook in cooks) _CookCard(cook: cook),
        if (_plan?.note case final note?) ...[
          const SizedBox(height: 8),
          Text(note, style: text.bodySmall?.copyWith(color: muted)),
        ],
      ],
    );
  }
}

class _CookCard extends StatelessWidget {
  const _CookCard({required this.cook});

  final PlannedCook cook;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(cook.name, style: text.titleMedium)),
                Text('× ${cook.servings}', style: text.titleMedium),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                if (cook.saved) 'One of yours' else 'New recipe',
                ?cook.covers,
              ].join(' · '),
              style: text.labelSmall?.copyWith(color: muted),
            ),
            if (cook.ingredients.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                cook.ingredients
                    .map((i) => '${i.name} ${i.grams.round()} g')
                    .join(' · '),
                style: text.bodySmall?.copyWith(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

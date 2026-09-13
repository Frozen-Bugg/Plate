import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'add_food_sheet.dart';
import 'draft_recipe_sheet.dart';
import 'meals_repository.dart';
import 'prep_screen.dart';
import 'recipes_repository.dart';

/// Everything cooked more than once.
///
/// A recipe is a plan, not a log: it follows its foods, and logging a portion
/// of it freezes what that portion contained. See `recipes_repository.dart`.
class RecipesScreen extends ConsumerStatefulWidget {
  const RecipesScreen({super.key, this.day, this.slot});

  /// When opened from the day log, logging a portion returns to it.
  final String? day;
  final String? slot;

  @override
  ConsumerState<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends ConsumerState<RecipesScreen> {
  final _search = TextEditingController();
  var _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = await _askForName(context, title: 'New recipe');
    if (name == null || !mounted) return;

    final id = await ref.read(recipesRepositoryProvider).create(name: name);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecipeScreen(id: id, day: widget.day, slot: widget.slot),
      ),
    );
  }

  Future<void> _draft() async {
    final id = await showDraftRecipeSheet(context);
    if (id == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecipeScreen(id: id, day: widget.day, slot: widget.slot),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final all = ref.watch(recipesProvider).value;

    final needle = _query.trim().toLowerCase();
    final shown = all == null
        ? const <RecipeDetail>[]
        : [
            for (final r in all)
              if (needle.isEmpty || r.name.toLowerCase().contains(needle)) r,
          ];

    return Scaffold(
      appBar: AppBar(title: const Text('Recipes')),
      // Two ways to start one. Describing it is faster when the dish exists
      // in your head and not yet on the shelf; the empty form is for when you
      // are standing over the pan already.
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'blank-recipe',
            tooltip: 'Start an empty recipe',
            onPressed: _create,
            child: const Icon(Icons.add),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'draft-recipe',
            onPressed: _draft,
            icon: const Icon(Icons.auto_awesome_outlined),
            label: const Text('Describe a dish'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Only worth the space once there are enough recipes to lose one in.
          if ((all?.length ?? 0) > 6)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(
                  hintText: 'Search recipes',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          Expanded(
            child: switch ((all, shown.isEmpty)) {
              (null, _) => const Center(child: CircularProgressIndicator()),
              (_, true) when needle.isNotEmpty => Center(
                  child: Text(
                    'No recipe matches "$_query".',
                    style: text.bodyMedium?.copyWith(color: muted),
                  ),
                ),
              (_, true) => const _NoRecipes(),
              _ => ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  itemCount: shown.length,
                  itemBuilder: (_, i) => _RecipeCard(
                    recipe: shown[i],
                    day: widget.day,
                    slot: widget.slot,
                  ),
                ),
            },
          ),
        ],
      ),
    );
  }
}

class _NoRecipes extends StatelessWidget {
  const _NoRecipes();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.soup_kitchen_outlined, size: 40, color: muted),
            const SizedBox(height: 12),
            Text('Nothing saved yet', style: text.titleMedium),
            const SizedBox(height: 6),
            Text(
              'A recipe is worth saving when you have cooked it twice. The '
              'quickest way in is the day log — open a meal you have already '
              'eaten and save it as a recipe. Or describe a dish and let the '
              'coach draft one.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecipeCard extends ConsumerWidget {
  const _RecipeCard({required this.recipe, this.day, this.slot});

  final RecipeDetail recipe;
  final String? day;
  final String? slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final each = recipe.perServing;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        title: Text(recipe.name),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            recipe.isEmpty
                ? 'No ingredients yet'
                : '${each.kcal.round()} kcal a serving · '
                    'P ${each.proteinG.round()} · '
                    'C ${each.carbG.round()} · '
                    'F ${each.fatG.round()}',
            style: text.labelSmall?.copyWith(color: muted),
          ),
        ),
        trailing: IconButton(
          tooltip: recipe.recipe.favourite ? 'Unpin' : 'Pin to the top',
          icon: Icon(
            recipe.recipe.favourite ? Icons.star : Icons.star_border,
            size: 20,
          ),
          onPressed: () => ref.read(recipesRepositoryProvider).update(
                recipe.id,
                favourite: !recipe.recipe.favourite,
              ),
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RecipeScreen(id: recipe.id, day: day, slot: slot),
          ),
        ),
      ),
    );
  }
}

/// One recipe: what is in it, what it makes, and logging a portion.
class RecipeScreen extends ConsumerWidget {
  const RecipeScreen({super.key, required this.id, this.day, this.slot});

  final String id;
  final String? day;
  final String? slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipe = ref.watch(recipeProvider(id)).value;
    if (recipe == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(
        title: Text(recipe.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (choice) async {
              switch (choice) {
                case 'rename':
                  final name = await _askForName(
                    context,
                    title: 'Rename',
                    initial: recipe.name,
                  );
                  // Read where it is used, not in build: the repository throws
                  // while signed out, and a screen that cannot even render
                  // without a session is a screen that cannot be tested.
                  if (name != null) {
                    await ref
                        .read(recipesRepositoryProvider)
                        .update(id, name: name);
                  }
                case 'cooks':
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const PrepScreen()),
                  );
                case 'delete':
                  final gone = await _confirmDelete(context, ref, recipe.name);
                  if (gone && context.mounted) Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'cooks', child: Text('Every cook')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      // Eating some now and cooking a batch for the week are different
      // moments, and prep is the one that needs to be the easy one.
      floatingActionButton: recipe.isEmpty
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.small(
                  heroTag: 'log-cook',
                  tooltip: 'Cooked a batch of this',
                  onPressed: () async {
                    final id = await showLogCookSheet(
                      context,
                      ref,
                      recipe: recipe,
                    );
                    if (id == null || !context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('In the fridge. It is on the day log.'),
                        duration: Duration(seconds: 3),
                      ),
                    );
                  },
                  child: const Icon(Icons.kitchen_outlined),
                ),
                const SizedBox(height: 10),
                FloatingActionButton.extended(
                  heroTag: 'log-portion',
                  onPressed: () => _logPortion(context, ref, recipe),
                  icon: const Icon(Icons.restaurant),
                  label: const Text('Log a portion'),
                ),
              ],
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          _Yield(recipe: recipe),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  'INGREDIENTS',
                  style: text.labelSmall
                      ?.copyWith(color: muted, letterSpacing: 1),
                ),
              ),
              TextButton.icon(
                onPressed: () => _addIngredient(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
            ],
          ),
          if (recipe.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'Nothing in it yet. Add what went in the pan, by weight — the '
                'macros come from the ingredients, not from the finished dish.',
                style: text.bodySmall?.copyWith(color: muted),
              ),
            ),
          for (final ingredient in recipe.ingredients)
            _IngredientRow(ingredient: ingredient),
        ],
      ),
    );
  }

  Future<void> _addIngredient(BuildContext context, WidgetRef ref) async {
    final picked = await showFoodPicker(context);
    if (picked == null) return;
    await ref.read(recipesRepositoryProvider).addIngredient(
          recipeId: id,
          foodId: picked.food.id,
          quantityG: picked.grams,
        );
  }

  Future<bool> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String name,
  ) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text(
          'The recipe goes. Meals already logged from it stay exactly as they '
          'are — they carry their own numbers.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true) return false;
    await ref.read(recipesRepositoryProvider).delete(id);
    return true;
  }

  Future<void> _logPortion(
    BuildContext context,
    WidgetRef ref,
    RecipeDetail recipe,
  ) async {
    final result = await showPortionSheet(
      context,
      name: recipe.name,
      servingWeightG: recipe.servingWeightG,
      isWeighed: recipe.isWeighed,
      nutritionFor: recipe.nutritionForGrams,
      subtitle: recipe.isWeighed
          ? 'Weighed: ${recipe.weightG.round()} g makes ${recipe.servings}'
          : 'Not weighed — a serving is assumed to be '
              '${recipe.servingWeightG.round()} g',
      slot: slot ?? 'dinner',
    );
    if (result == null) return;

    await ref.read(recipesRepositoryProvider).logToMeal(
          recipe: recipe,
          grams: result.grams,
          slot: result.slot,
          day: day,
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${recipe.name} · ${result.grams.round()} g · '
          '${recipe.nutritionForGrams(result.grams).kcal.round()} kcal',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// What the pot makes: servings, weight, and what one of them contains.
///
/// The cooked weight sits here rather than buried in a menu because it is the
/// number that decides whether a portion is right. Rice doubles in the pan; a
/// recipe portioned by its raw weight is wrong by however much water it took.
class _Yield extends ConsumerWidget {
  const _Yield({required this.recipe});

  final RecipeDetail recipe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final each = recipe.perServing;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Makes', style: text.labelLarge),
                const Spacer(),
                _Stepper(
                  value: recipe.servings,
                  onChanged: (v) => ref
                      .read(recipesRepositoryProvider)
                      .update(recipe.id, servings: v),
                ),
                const SizedBox(width: 8),
                Text(
                  recipe.servings == 1 ? 'serving' : 'servings',
                  style: text.bodyMedium?.copyWith(color: muted),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${each.kcal.round()}', style: text.headlineMedium),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'kcal a serving',
                    style: text.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'P ${each.proteinG.round()} · C ${each.carbG.round()} · '
              'F ${each.fatG.round()}'
              '${recipe.servingWeightG > 0 ? ' · ${recipe.servingWeightG.round()} g each' : ''}',
              style: text.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            _CookedWeight(recipe: recipe),
          ],
        ),
      ),
    );
  }
}

/// The measured yield, and the nudge to measure it.
class _CookedWeight extends ConsumerWidget {
  const _CookedWeight({required this.recipe});

  final RecipeDetail recipe;

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final grams = await _askForNumber(
      context,
      title: 'Cooked weight',
      hint: 'Grams out of the pan',
      helper: 'Weigh the finished dish. The difference from the raw weight is '
          'water, which changes the portion size and not the macros.',
      initial: recipe.recipe.totalWeightG ?? recipe.rawWeightG,
    );
    if (grams == null) return;
    await ref.read(recipesRepositoryProvider).update(
          recipe.id,
          totalWeightG: grams > 0 ? grams : null,
          clearTotalWeight: grams <= 0,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    if (recipe.isEmpty) return const SizedBox.shrink();

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _edit(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(
              recipe.isWeighed ? Icons.scale : Icons.scale_outlined,
              size: 18,
              color: muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                recipe.isWeighed
                    ? 'Cooked weight ${recipe.weightG.round()} g '
                        '(raw ${recipe.rawWeightG.round()} g)'
                    : 'Not weighed — portions assume ${recipe.rawWeightG.round()} g',
                style: text.bodySmall?.copyWith(color: muted),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: muted),
          ],
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: value > 1 ? () => onChanged(value - 1) : null,
        ),
        Text('$value', style: Theme.of(context).textTheme.titleMedium),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_circle_outline),
          onPressed: value < 100 ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}

class _IngredientRow extends ConsumerWidget {
  const _IngredientRow({required this.ingredient});

  final Ingredient ingredient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final gone = ingredient.food == null;

    return Dismissible(
      key: ValueKey(ingredient.id),
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
          ref.read(recipesRepositoryProvider).removeIngredient(ingredient.id),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(
          ingredient.name,
          style: gone ? text.bodyMedium?.copyWith(color: muted) : null,
        ),
        subtitle: Text(
          gone
              ? 'This food was deleted — it counts as nothing'
              : '${ingredient.nutrition.kcal.round()} kcal · '
                  'P ${ingredient.nutrition.proteinG.round()}',
          style: text.labelSmall?.copyWith(color: muted),
        ),
        trailing: Text('${ingredient.quantityG.round()} g',
            style: text.labelLarge),
        onTap: gone
            ? null
            : () async {
                final grams = await showQuantitySheet(
                  context,
                  food: ingredient.food!,
                  initialGrams: ingredient.quantityG,
                  cta: 'Save',
                );
                if (grams == null) return;
                await ref
                    .read(recipesRepositoryProvider)
                    .setIngredientQuantity(ingredient.id, grams);
              },
      ),
    );
  }
}

/// How much of the pot went on the plate, and into which meal.
///
/// Servings first because that is how a prepped dish is eaten, grams underneath
/// because nobody portions a pot into four identical tubs.
///
/// Takes the numbers rather than the recipe, so a batch out of the fridge uses
/// the same sheet: the only difference between them is which weight a portion
/// is measured against, and that is already decided by the time it gets here.
Future<({double grams, String slot})?> showPortionSheet(
  BuildContext context, {
  required String name,
  required double servingWeightG,
  required bool isWeighed,
  required Nutrition Function(double grams) nutritionFor,
  String? subtitle,
  double? maxGrams,
  String slot = 'dinner',
}) {
  return showModalBottomSheet<({double grams, String slot})>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _PortionSheet(
        name: name,
        servingWeightG: servingWeightG,
        isWeighed: isWeighed,
        nutritionFor: nutritionFor,
        subtitle: subtitle,
        maxGrams: maxGrams,
        slot: slot,
      ),
    ),
  );
}

class _PortionSheet extends StatefulWidget {
  const _PortionSheet({
    required this.name,
    required this.servingWeightG,
    required this.isWeighed,
    required this.nutritionFor,
    required this.slot,
    this.subtitle,
    this.maxGrams,
  });

  final String name;
  final double servingWeightG;
  final bool isWeighed;
  final Nutrition Function(double grams) nutritionFor;
  final String? subtitle;

  /// What is actually left, when there is a limit — a tub cannot give up more
  /// than it holds.
  final double? maxGrams;
  final String slot;

  @override
  State<_PortionSheet> createState() => _PortionSheetState();
}

class _PortionSheetState extends State<_PortionSheet> {
  late final _grams = TextEditingController(
    text: widget.servingWeightG.round().toString(),
  );
  late String _slot = widget.slot;

  @override
  void dispose() {
    _grams.dispose();
    super.dispose();
  }

  double get _value => double.tryParse(_grams.text.trim()) ?? 0;

  /// Over what is left is a mis-weighed tub rather than a second helping, so
  /// it is worth saying before it becomes a portion nobody can account for.
  bool get _tooMuch =>
      widget.maxGrams != null && _value > widget.maxGrams! + 1;

  void _setServings(double servings) {
    final grams = widget.servingWeightG * servings;
    setState(() => _grams.text = grams.round().toString());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final macros = widget.nutritionFor(_value);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.name, style: text.headlineSmall),
          if (widget.subtitle case final subtitle?) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: text.bodySmall?.copyWith(color: muted)),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              for (final servings in const [0.5, 1.0, 1.5, 2.0])
                ActionChip(
                  label: Text(servings == 1
                      ? '1 serving'
                      : '$servings servings'.replaceAll('.0', '')),
                  onPressed: () => _setServings(servings),
                ),
              if (widget.maxGrams != null && widget.maxGrams! > 0)
                ActionChip(
                  label: const Text('All of it'),
                  onPressed: () => setState(
                    () => _grams.text = widget.maxGrams!.round().toString(),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _grams,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Grams',
              helperText: widget.isWeighed
                  ? 'Weigh the tub if you can — it beats counting'
                  : 'Not weighed, so a serving is an estimate',
              errorText: _tooMuch
                  ? 'Only ${widget.maxGrams!.round()} g left in it'
                  : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Text(
            '${macros.kcal.round()} kcal · P ${macros.proteinG.round()} · '
            'C ${macros.carbG.round()} · F ${macros.fatG.round()}',
            style: text.titleMedium,
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: [
              for (final slot in mealSlots)
                ButtonSegment(
                  value: slot,
                  label: Text(
                    slot == 'snack'
                        ? 'Snacks'
                        : '${slot[0].toUpperCase()}${slot.substring(1)}',
                  ),
                ),
            ],
            selected: {_slot},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _slot = s.first),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _value > 0
                ? () => Navigator.of(context).pop((grams: _value, slot: _slot))
                : null,
            child: const Text('Log it'),
          ),
        ],
      ),
    );
  }
}

Future<String?> _askForName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Chicken rice bowl'),
        onSubmitted: (v) =>
            Navigator.of(context).pop(v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final value = controller.text.trim();
            Navigator.of(context).pop(value.isEmpty ? null : value);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<double?> _askForNumber(
  BuildContext context, {
  required String title,
  required String hint,
  String? helper,
  double initial = 0,
}) {
  final controller =
      TextEditingController(text: initial > 0 ? initial.round().toString() : '');
  return showDialog<double>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          hintText: hint,
          helperText: helper,
          helperMaxLines: 4,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context)
              .pop(double.tryParse(controller.text.trim()) ?? 0),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

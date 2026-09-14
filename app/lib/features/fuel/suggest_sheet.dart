import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import 'foods_repository.dart';
import 'prep_repository.dart';
import 'recipes_repository.dart';
import 'recipes_screen.dart';
import 'suggest_service.dart';

/// "What should I eat?", answered in three options.
///
/// Opened from the day log, because that is where the question is asked — at
/// six in the evening, looking at the rings.
///
/// The options outlive the sheet. They are held in [suggestionsProvider], so
/// closing this and opening it again shows the same three, and the one you were
/// half-decided on is still there. Refresh is a button, not a side effect of
/// looking.
///
/// Nothing here logs anything. An option becomes a **recipe** — read it, cook
/// it, log a portion from the recipe screen like any other — except food
/// already in the fridge, which is logged against its batch so the remainder
/// comes down.
Future<void> showSuggestSheet(
  BuildContext context, {
  required String day,
  String slot = 'dinner',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _SuggestSheet(day: day, slot: slot),
    ),
  );
}

class _SuggestSheet extends ConsumerStatefulWidget {
  const _SuggestSheet({required this.day, required this.slot});

  final String day;
  final String slot;

  @override
  ConsumerState<_SuggestSheet> createState() => _SuggestSheetState();
}

class _SuggestSheetState extends ConsumerState<_SuggestSheet> {
  final _note = TextEditingController();

  /// The option being turned into a recipe, if any. Named rather than a bool so
  /// the spinner lands on the row that was tapped.
  String? _opening;

  @override
  void initState() {
    super.initState();
    // Only if there is nothing for today already. This is the whole fix: the
    // sheet no longer asks a fresh question every time it is opened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(suggestionsProvider.notifier).ensure(day: widget.day);
    });
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final state = ref.watch(suggestionsProvider);
    final result = state.suggestions;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.82,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('What should I eat?', style: text.headlineSmall),
                ),
                IconButton(
                  tooltip: 'Ask again',
                  onPressed: state.asking
                      ? null
                      : () => ref
                          .read(suggestionsProvider.notifier)
                          .ensure(day: widget.day, force: true),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            Text(
              switch (result?.leftKcal) {
                null => 'Nothing is set as a target, so these are ordinary '
                    'meals rather than ones that fit.',
                final left when left <= 0 =>
                  'You are over for today. These would put you further over.',
                final left => '${left.round()} kcal left'
                    '${result?.leftProteinG == null ? '' : ' · '
                        '${result!.leftProteinG!.round()} g protein'}',
              },
              style: text.bodyMedium?.copyWith(color: muted),
            ),
            if (result?.urgent case final urgent?) ...[
              const SizedBox(height: 10),
              _UrgentBanner(text: urgent),
            ],
            const SizedBox(height: 12),
            Expanded(child: _body(context, state)),
            const SizedBox(height: 8),
            // The pantry that is not a table. Said once, for this question.
            TextField(
              controller: _note,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: 'Anything to work with? "chicken and rice"',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: state.asking ? null : _askWithNote,
                ),
              ),
              onSubmitted: (_) => _askWithNote(),
            ),
          ],
        ),
      ),
    );
  }

  void _askWithNote() {
    ref.read(suggestionsProvider.notifier).askWith(
          day: widget.day,
          note: _note.text,
        );
  }

  Widget _body(BuildContext context, SuggestionsState state) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    if (state.asking && state.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error case final error?) {
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
            OutlinedButton(
              onPressed: () => ref
                  .read(suggestionsProvider.notifier)
                  .ensure(day: widget.day, force: true),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }

    final options = state.suggestions?.options ?? const <Suggestion>[];
    if (options.isEmpty) {
      return Center(
        child: Text(
          'Nothing came back. Try again, or say what you have in.',
          style: text.bodyMedium?.copyWith(color: muted),
        ),
      );
    }

    return Stack(
      children: [
        ListView(
          children: [
            for (final option in options)
              _OptionCard(
                option: option,
                day: widget.day,
                slot: widget.slot,
                busy: _opening == option.name,
                onOpen: () => _open(option),
              ),
          ],
        ),
        // A refresh keeps the old answers on screen while it runs.
        if (state.asking)
          const Positioned(
            top: 0,
            right: 0,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }

  /// Turns an option into something you can cook and log.
  ///
  /// Food in the fridge stays a portion of its batch — that is the accounting
  /// that keeps the remainder right, and there is nothing to cook. Everything
  /// else ends up on the recipe screen, which is where a recipe is read and
  /// where a portion is logged.
  Future<void> _open(Suggestion option) async {
    if (_opening != null) return;

    if (option.fromPrep case final name?) {
      final batch = ref
          .read(prepOnHandProvider)
          .where((b) => b.name.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      if (batch != null) {
        await _eatFromFridge(batch);
        return;
      }
    }

    setState(() => _opening = option.name);
    try {
      final id = await _recipeFor(option);
      if (id == null || !mounted) return;

      // The sheet closes and the recipe opens. Coming back for another option
      // means reopening the sheet, which now holds the same three.
      Navigator.of(context).pop();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              RecipeScreen(id: id, day: widget.day, slot: widget.slot),
        ),
      );
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _eatFromFridge(Batch batch) async {
    final result = await showPortionSheet(
      context,
      name: batch.name,
      servingWeightG: batch.servingWeightG,
      isWeighed: batch.isWeighed,
      nutritionFor: batch.nutritionForGrams,
      maxGrams: batch.gramsLeft,
      subtitle: '${batch.gramsLeft.round()} g left in the fridge',
      slot: widget.slot,
    );
    if (result == null) return;

    await ref.read(prepRepositoryProvider).logPortion(
          batch: batch,
          grams: result.grams,
          slot: result.slot,
          day: widget.day,
        );
    if (mounted) Navigator.of(context).pop();
  }

  /// The recipe behind an option, saving a new one if there is not one yet.
  Future<String?> _recipeFor(Suggestion option) async {
    final saved = ref.read(recipesProvider).value ?? const <RecipeDetail>[];

    // One of theirs, named exactly: open it rather than drafting a second copy.
    final name = option.fromRecipe ?? option.name;
    final existing = saved
        .where((r) => r.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (existing != null) return existing.id;

    // A new idea. Drafting it is a second model call, which is why it happens
    // on the tap rather than for all three up front — two of them are never
    // opened.
    try {
      final draft = await ref
          .read(draftServiceProvider)
          .draftRecipe('${option.name}. ${option.why}');

      final recipes = ref.read(recipesRepositoryProvider);
      final foods = ref.read(foodsRepositoryProvider);
      final id = await recipes.create(
        name: draft.name,
        servings: draft.servings,
        steps: draft.steps,
      );

      // Same order as the drafter: the shelf first, then the coach, and
      // anything priced by the coach is saved as an estimate.
      final matched = <String, Food?>{};
      for (final ingredient in draft.ingredients) {
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
            for (final missing in unpriced) {
              if (missing.trim().toLowerCase() ==
                  estimate.name.trim().toLowerCase()) {
                matched[missing] = await foods.remember(estimate.facts);
              }
            }
          }
        } catch (_) {
          // The recipe is short by whatever could not be priced, and its own
          // screen says which.
        }
      }

      for (final ingredient in draft.ingredients) {
        if (matched[ingredient.name] case final food?) {
          await recipes.addIngredient(
            recipeId: id,
            foodId: food.id,
            quantityG: ingredient.grams,
          );
        }
      }
      return id;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not write that one up.')),
        );
      }
      return null;
    }
  }
}

class _UrgentBanner extends StatelessWidget {
  const _UrgentBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule,
              size: 18, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionCard extends ConsumerWidget {
  const _OptionCard({
    required this.option,
    required this.day,
    required this.slot,
    required this.busy,
    required this.onOpen,
  });

  final Suggestion option;
  final String day;
  final String slot;
  final bool busy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: busy ? null : onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(option.name, style: text.titleMedium)),
                  Text('${option.kcal.round()}', style: text.titleMedium),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'P ${option.proteinG.round()} · C ${option.carbG.round()} · '
                'F ${option.fatG.round()}',
                style: text.labelSmall?.copyWith(color: muted),
              ),
              if (option.why.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(option.why, style: text.bodySmall),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  if (option.fromPrep != null)
                    _Tag(icon: Icons.kitchen_outlined, label: 'In the fridge')
                  else if (option.fromRecipe != null)
                    _Tag(icon: Icons.menu_book_outlined, label: 'Saved recipe')
                  else
                    _Tag(
                      icon: Icons.auto_awesome_outlined,
                      label: 'Writes up as a recipe',
                    ),
                  const Spacer(),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    TextButton(
                      onPressed: onOpen,
                      child: Text(option.isCooked ? 'Eat it' : 'Recipe'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: muted),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style:
                Theme.of(context).textTheme.labelSmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

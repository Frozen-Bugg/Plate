import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'add_food_sheet.dart';
import 'prep_repository.dart';
import 'quick_add_service.dart';
import 'recipes_repository.dart';
import 'recipes_screen.dart';
import 'suggest_service.dart';

/// "What should I eat?", answered in three options.
///
/// Opened from the day log, because that is where the question is asked — at
/// six in the evening, looking at the rings. Nothing here logs anything by
/// itself: an option is a thing to consider, and logging it is a second tap
/// through the sheets that already exist.
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
  Suggestions? _result;
  String? _error;
  var _asking = false;

  @override
  void initState() {
    super.initState();
    // Asked immediately: the common case is having nothing to add, and making
    // someone type before they are offered anything is a sheet nobody opens.
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
      final result = await ref.read(suggestServiceProvider).suggest(
            day: widget.day,
            note: _note.text,
          );
      if (mounted) setState(() => _result = result);
    } on QuickAddError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'The coach could not answer just now.');
      }
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final result = _result;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('What should I eat?', style: text.headlineSmall),
            const SizedBox(height: 4),
            Text(
              switch (result?.leftKcal) {
                null => 'Nothing is logged as a target, so these are ordinary '
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
            Expanded(child: _body(context)),
            const SizedBox(height: 8),
            // The pantry that is not a table. Said once, for this question.
            TextField(
              controller: _note,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: 'Anything to work with? "chicken and rice"',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _asking ? null : _ask,
                ),
              ),
              onSubmitted: (_) => _ask(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    if (_asking && _result == null) {
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

    final options = _result?.options ?? const <Suggestion>[];
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
              _OptionCard(option: option, day: widget.day, slot: widget.slot),
          ],
        ),
        // Re-asking keeps the old answers on screen: a blank sheet while it
        // thinks loses the option they were half-decided on.
        if (_asking)
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
          Icon(Icons.schedule, size: 18, color: theme.colorScheme.onErrorContainer),
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

/// One option, and the way to log it.
///
/// Food already cooked logs through the batch, so the portion comes out of the
/// fridge and the remainder goes down. Anything else opens the ordinary food
/// search with the name filled in — the coach's guess at 412 kcal is not
/// something to write into a log as fact.
class _OptionCard extends ConsumerWidget {
  const _OptionCard({
    required this.option,
    required this.day,
    required this.slot,
  });

  final Suggestion option;
  final String day;
  final String slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
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
                  _Tag(icon: Icons.auto_awesome_outlined, label: 'Estimate'),
                const Spacer(),
                TextButton(
                  onPressed: () => _log(context, ref),
                  child: Text(option.isCooked ? 'Eat it' : 'Log it'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _log(BuildContext context, WidgetRef ref) async {
    // Food in the fridge: log the portion against the batch, so the remainder
    // comes down and the macros are the real ones rather than the suggestion's.
    if (option.fromPrep case final name?) {
      final batch = ref
          .read(prepOnHandProvider)
          .where((b) => b.name.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      if (batch != null) {
        final result = await showPortionSheet(
          context,
          name: batch.name,
          servingWeightG: batch.servingWeightG,
          isWeighed: batch.isWeighed,
          nutritionFor: batch.nutritionForGrams,
          maxGrams: batch.gramsLeft,
          subtitle: '${batch.gramsLeft.round()} g left in the fridge',
          slot: slot,
        );
        if (result == null) return;
        await ref.read(prepRepositoryProvider).logPortion(
              batch: batch,
              grams: result.grams,
              slot: result.slot,
              day: day,
            );
        if (context.mounted) Navigator.of(context).pop();
        return;
      }
    }

    // One of their recipes: log a portion of the real thing.
    if (option.fromRecipe case final name?) {
      final recipe = (ref.read(recipesProvider).value ?? const <RecipeDetail>[])
          .where((r) => r.name.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      if (recipe != null && context.mounted) {
        final result = await showPortionSheet(
          context,
          name: recipe.name,
          servingWeightG: recipe.servingWeightG,
          isWeighed: recipe.isWeighed,
          nutritionFor: recipe.nutritionForGrams,
          slot: slot,
        );
        if (result == null) return;
        await ref.read(recipesRepositoryProvider).logToMeal(
              recipe: recipe,
              grams: result.grams,
              slot: result.slot,
              day: day,
            );
        if (context.mounted) Navigator.of(context).pop();
        return;
      }
    }

    // Everything else is a suggestion, not a food. The coach's 412 kcal is a
    // guess about a meal that does not exist yet, and writing a guess into the
    // log as fact is what docs/PLAN.md §11 exists to stop. So this opens the
    // ordinary search instead.
    if (!context.mounted) return;
    Navigator.of(context).pop();
    await showAddFoodSheet(context, day: day, slot: slot, search: option.name);
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
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}

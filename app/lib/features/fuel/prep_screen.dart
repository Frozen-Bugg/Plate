import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/day.dart';
import 'prep_repository.dart';
import 'recipes_repository.dart';
import 'recipes_screen.dart';

/// What is in the fridge, on the day log.
///
/// Sits above the meal slots because it is the first answer to "what am I
/// eating", and because prep only pays off if eating it is easier than not.
/// Hidden entirely when there is nothing cooked — an empty card teaching a
/// feature is worse than no card.
class FridgeCard extends ConsumerWidget {
  const FridgeCard({super.key, required this.day});

  final String day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batches = ref.watch(prepOnHandProvider);
    if (batches.isEmpty) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
              child: Row(
                children: [
                  Icon(Icons.kitchen_outlined, size: 18, color: muted),
                  const SizedBox(width: 8),
                  Text('IN THE FRIDGE',
                      style: text.labelSmall
                          ?.copyWith(color: muted, letterSpacing: 1)),
                ],
              ),
            ),
            for (final batch in batches)
              _BatchRow(batch: batch, day: day),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

class _BatchRow extends ConsumerWidget {
  const _BatchRow({required this.batch, required this.day});

  final Batch batch;
  final String day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final urgent = batch.needsEating;

    return ListTile(
      dense: true,
      title: Text(batch.name),
      subtitle: Text(
        [
          '${_servings(batch.servingsLeft)} left',
          '${batch.perServing.kcal.round()} kcal each',
          ?_useBy(batch),
        ].join(' · '),
        style: text.labelSmall?.copyWith(
          color: urgent ? theme.colorScheme.error : muted,
        ),
      ),
      trailing: FilledButton.tonal(
        onPressed: () => _eat(context, ref),
        child: const Text('Eat'),
      ),
    );
  }

  /// "2" rather than "2.0", and "half" rather than "0.5 servings".
  static String _servings(double value) {
    if (value < 0.75) return 'half a serving';
    final rounded = (value * 2).round() / 2;
    final label = rounded == rounded.roundToDouble()
        ? rounded.round().toString()
        : rounded.toString();
    return rounded == 1 ? '1 serving' : '$label servings';
  }

  static String? _useBy(Batch batch) {
    final days = batch.daysLeft;
    if (days == null) return null;
    return switch (days) {
      <= 0 => 'eat today',
      1 => 'eat by tomorrow',
      _ => '$days days left',
    };
  }

  Future<void> _eat(BuildContext context, WidgetRef ref) async {
    final result = await showPortionSheet(
      context,
      name: batch.name,
      servingWeightG: batch.servingWeightG,
      isWeighed: batch.isWeighed,
      nutritionFor: batch.nutritionForGrams,
      maxGrams: batch.gramsLeft,
      subtitle: 'Cooked ${_when(batch.cookedOn)} · '
          '${batch.gramsLeft.round()} g left of ${batch.weightG.round()} g',
      slot: 'lunch',
    );
    if (result == null) return;

    await ref.read(prepRepositoryProvider).logPortion(
          batch: batch,
          grams: result.grams,
          slot: result.slot,
          day: day,
        );
  }

  static String _when(String cookedOn) {
    final days =
        parseDayKey(dayKey()).difference(parseDayKey(cookedOn)).inDays;
    return switch (days) {
      0 => 'today',
      1 => 'yesterday',
      _ => '$days days ago',
    };
  }
}

/// Records a cook: how many portions it made, and what it weighed.
///
/// The weight is seeded from the recipe's expected yield and meant to be
/// corrected on the scales, because this pot is the one being eaten.
Future<String?> showLogCookSheet(
  BuildContext context,
  WidgetRef ref, {
  required RecipeDetail recipe,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _LogCookSheet(recipe: recipe),
    ),
  );
}

class _LogCookSheet extends ConsumerStatefulWidget {
  const _LogCookSheet({required this.recipe});

  final RecipeDetail recipe;

  @override
  ConsumerState<_LogCookSheet> createState() => _LogCookSheetState();
}

class _LogCookSheetState extends ConsumerState<_LogCookSheet> {
  late int _servings = widget.recipe.servings;
  late final _weight = TextEditingController(
    text: widget.recipe.weightG > 0
        ? widget.recipe.weightG.round().toString()
        : '',
  );

  /// Three days is the default because it is the honest one for cooked food in
  /// a fridge, and a default nobody would follow is worse than none.
  int _keeps = 3;
  var _saving = false;

  @override
  void dispose() {
    _weight.dispose();
    super.dispose();
  }

  double get _weightValue => double.tryParse(_weight.text.trim()) ?? 0;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    final useBy = dayKey(
      parseDayKey(dayKey()).add(Duration(days: _keeps)),
    );
    final id = await ref.read(prepRepositoryProvider).logCook(
          recipeId: widget.recipe.id,
          servingsMade: _servings,
          cookedWeightG: _weightValue > 0 ? _weightValue : null,
          useBy: useBy,
        );
    if (mounted) Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final each = _weightValue > 0 && _servings > 0
        ? widget.recipe.scaledBy(1 / _servings)
        : widget.recipe.perServing;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Cooked ${widget.recipe.name}', style: text.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Logging the cook, not the meal. Eat it from the fridge and it '
            'goes in the day log then.',
            style: text.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Text('Portions', style: text.titleSmall),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed:
                    _servings > 1 ? () => setState(() => _servings--) : null,
              ),
              Text('$_servings', style: text.titleMedium),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed:
                    _servings < 100 ? () => setState(() => _servings++) : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _weight,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Cooked weight (g)',
              helperText: 'Weigh the pan. The difference from the raw weight '
                  'is water — it changes the portion size, not the macros.',
              helperMaxLines: 3,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Text('KEEPS FOR',
              style:
                  text.labelSmall?.copyWith(color: muted, letterSpacing: 1)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final days in const [2, 3, 4, 5])
                ChoiceChip(
                  label: Text('$days days'),
                  selected: _keeps == days,
                  onSelected: (_) => setState(() => _keeps = days),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            '${each.kcal.round()} kcal a portion · P ${each.proteinG.round()} '
            '· C ${each.carbG.round()} · F ${each.fatG.round()}',
            style: text.titleMedium,
          ),
          if (_weightValue > 0 && _servings > 0) ...[
            const SizedBox(height: 2),
            Text(
              '${(_weightValue / _servings).round()} g each',
              style: text.bodySmall?.copyWith(color: muted),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('Into the fridge'),
          ),
        ],
      ),
    );
  }
}

/// Every cook, including the ones that are gone.
///
/// Mostly a way to correct a batch after the fact — the portions were four and
/// turned out to be three — and to see whether prep is actually being eaten.
class PrepScreen extends ConsumerWidget {
  const PrepScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final batches = ref.watch(prepBatchesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Cooks')),
      body: batches.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Nothing cooked yet. Open a recipe and log a cook when you '
                  'have made a batch of it.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: muted),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: batches.length,
              itemBuilder: (_, i) {
                final batch = batches[i];
                final done = batch.isFinished;

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    title: Text(
                      batch.name,
                      style: done
                          ? text.bodyLarge?.copyWith(color: muted)
                          : null,
                    ),
                    subtitle: Text(
                      done
                          ? 'Cooked ${batch.cookedOn} · finished'
                          : 'Cooked ${batch.cookedOn} · '
                              '${batch.gramsLeft.round()} g left',
                      style: text.labelSmall?.copyWith(color: muted),
                    ),
                    trailing: done
                        ? null
                        : IconButton(
                            tooltip: 'Throw the rest away',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => ref
                                .read(prepRepositoryProvider)
                                .discard(batch.id),
                          ),
                  ),
                );
              },
            ),
    );
  }
}

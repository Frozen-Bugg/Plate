import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import 'add_food_sheet.dart';
import 'foods_repository.dart';
import 'meals_repository.dart';
import 'quick_add_service.dart';
import 'recipes_repository.dart';
import 'suggest_service.dart';

/// "Make me a recipe for that."
///
/// The coach returns names and weights and **no macros at all** — see
/// `coach-api/src/tools/draft.ts`. Every number on this screen is summed from
/// food rows on this device, which is why the total can be trusted and why an
/// ingredient the shelf does not have shows as a gap rather than a guess.
Future<String?> showDraftRecipeSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: const _DraftSheet(),
    ),
  );
}

/// One drafted ingredient, and the food it was matched to.
class _Line {
  _Line({required this.name, required this.grams, this.note, this.food});

  final String name;
  double grams;
  final String? note;

  /// Null until something on the shelf matches. Everything numeric hangs off
  /// this, so a null here is a hole in the recipe and is shown as one.
  Food? food;

  Nutrition? get nutrition =>
      food == null ? null : nutritionFor(food!, grams);
}

class _DraftSheet extends ConsumerStatefulWidget {
  const _DraftSheet();

  @override
  ConsumerState<_DraftSheet> createState() => _DraftSheetState();
}

class _DraftSheetState extends ConsumerState<_DraftSheet> {
  final _description = TextEditingController();
  String? _name;
  String? _method;
  int _servings = 1;
  List<_Line> _lines = [];
  String? _error;
  var _asking = false;
  var _saving = false;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  bool get _hasDraft => _name != null;

  int get _unmatched => _lines.where((l) => l.food == null).length;

  Nutrition get _total => _lines.fold(
        (kcal: 0.0, proteinG: 0.0, carbG: 0.0, fatG: 0.0, fibreG: 0.0),
        (sum, line) {
          final macros = line.nutrition;
          if (macros == null) return sum;
          return (
            kcal: sum.kcal + macros.kcal,
            proteinG: sum.proteinG + macros.proteinG,
            carbG: sum.carbG + macros.carbG,
            fatG: sum.fatG + macros.fatG,
            fibreG: sum.fibreG + macros.fibreG,
          );
        },
      );

  Future<void> _draft() async {
    final said = _description.text.trim();
    if (said.isEmpty || _asking) return;

    setState(() {
      _asking = true;
      _error = null;
    });

    try {
      final draft = await ref.read(draftServiceProvider).draftRecipe(said);
      final foods = ref.read(foodsRepositoryProvider);

      // Matched here rather than on the server: the shelf is on the device,
      // and the server never sees a food id.
      final lines = <_Line>[];
      for (final ingredient in draft.ingredients) {
        lines.add(
          _Line(
            name: ingredient.name,
            grams: ingredient.grams,
            note: ingredient.note,
            food: await foods.bestMatch(ingredient.name),
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _name = draft.name;
        _servings = draft.servings;
        _method = draft.method;
        _lines = lines;
      });
    } on QuickAddError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'The coach could not answer.');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  Future<void> _find(_Line line) async {
    final picked = await showFoodPicker(
      context,
      title: 'Match "${line.name}"',
    );
    if (picked == null) return;
    setState(() {
      line.food = picked.food;
      line.grams = picked.grams;
    });
  }

  Future<void> _save() async {
    if (_saving || _name == null) return;
    setState(() => _saving = true);

    final repository = ref.read(recipesRepositoryProvider);
    final id = await repository.create(
      name: _name!,
      servings: _servings,
      notes: _method,
    );
    for (final line in _lines) {
      if (line.food case final food?) {
        await repository.addIngredient(
          recipeId: id,
          foodId: food.id,
          quantityG: line.grams,
        );
      }
    }
    if (mounted) Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_name ?? 'Draft a recipe', style: text.headlineSmall),
            const SizedBox(height: 4),
            Text(
              _hasDraft
                  ? 'Every number here is summed from your own foods. The '
                      'coach only chose what goes in and how much.'
                  : 'Describe the dish. "A chicken and rice thing for four '
                      'lunches", "high protein overnight oats".',
              style: text.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            if (!_hasDraft)
              TextField(
                controller: _description,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'What do you want to make?',
                ),
                onSubmitted: (_) => _draft(),
              ),
            Expanded(child: _body(context)),
            if (_hasDraft) _footer(context) else const SizedBox(height: 8),
            if (!_hasDraft)
              FilledButton(
                onPressed: _asking ? null : _draft,
                child: Text(_asking ? 'Thinking…' : 'Draft it'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    if (_asking && !_hasDraft) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error case final error?) {
      return Center(
        child: Text(
          error,
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: muted),
        ),
      );
    }
    if (!_hasDraft) return const SizedBox.shrink();

    return ListView(
      children: [
        Row(
          children: [
            Text('Makes', style: text.labelLarge),
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove_circle_outline),
              onPressed:
                  _servings > 1 ? () => setState(() => _servings--) : null,
            ),
            Text('$_servings', style: text.titleMedium),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_circle_outline),
              onPressed:
                  _servings < 100 ? () => setState(() => _servings++) : null,
            ),
          ],
        ),
        const Divider(),
        for (final line in _lines) _LineRow(line: line, onFind: () => _find(line)),
        if (_method case final method?) ...[
          const SizedBox(height: 12),
          Text(method, style: text.bodySmall?.copyWith(color: muted)),
        ],
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final each = _servings > 0
        ? (
            kcal: _total.kcal / _servings,
            proteinG: _total.proteinG / _servings,
            carbG: _total.carbG / _servings,
            fatG: _total.fatG / _servings,
          )
        : (kcal: 0.0, proteinG: 0.0, carbG: 0.0, fatG: 0.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        Text(
          '${each.kcal.round()} kcal a serving · P ${each.proteinG.round()} · '
          'C ${each.carbG.round()} · F ${each.fatG.round()}',
          style: text.titleMedium,
        ),
        if (_unmatched > 0) ...[
          const SizedBox(height: 4),
          Text(
            _unmatched == 1
                ? '1 ingredient is not in your foods yet, so it counts as '
                    'nothing. Match it or the total is short.'
                : '$_unmatched ingredients are not in your foods yet, so they '
                    'count as nothing. Match them or the total is short.',
            style: text.labelSmall?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_unmatched > 0 ? 'Save anyway' : 'Save recipe'),
        ),
        TextButton(
          onPressed: () => setState(() {
            _name = null;
            _lines = [];
          }),
          child: const Text('Start again'),
        ),
        const SizedBox(height: 2),
        Text(
          'Nothing is logged. Saving puts it in Recipes.',
          textAlign: TextAlign.center,
          style: text.labelSmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.onFind});

  final _Line line;
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final macros = line.nutrition;

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(line.food?.name ?? line.name),
      subtitle: Text(
        macros == null
            ? [
                'Not in your foods',
                ?line.note,
              ].join(' · ')
            : [
                '${macros.kcal.round()} kcal',
                'P ${macros.proteinG.round()}',
                ?line.note,
              ].join(' · '),
        style: text.labelSmall?.copyWith(
          color: macros == null ? theme.colorScheme.error : muted,
        ),
      ),
      trailing: macros == null
          ? TextButton(onPressed: onFind, child: const Text('Find'))
          : Text('${line.grams.round()} g', style: text.labelLarge),
      onTap: macros == null ? onFind : null,
    );
  }
}

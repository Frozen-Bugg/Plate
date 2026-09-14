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
/// `coach-api/src/tools/draft.ts`. Every number on this screen is summed here,
/// which is why the total can be trusted.
///
/// Ingredients are priced in the order docs/MEAL-PLANNING.md §3 sets out: a
/// food already on the shelf first, because somebody has checked that one; then
/// the coach, asked separately and only for nutrition, and marked as an
/// estimate everywhere it appears. Only a food that cannot be priced at all
/// counts as nothing, and the total says so when one does.
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
  _Line({
    required this.name,
    required this.grams,
    this.note,
    this.food,
  });

  final String name;
  double grams;
  final String? note;

  /// Something already on the shelf. Preferred over an estimate every time:
  /// it is a number somebody has already checked.
  Food? food;

  /// The coach's guess at this food, per 100 g, when the shelf had nothing.
  ///
  /// Held rather than saved. A food row is only written when the recipe is —
  /// otherwise every abandoned draft would leave guesses behind in the food
  /// list, and they would be indistinguishable from foods actually used.
  EstimatedFood? estimate;

  bool get isEstimate => food == null && estimate != null;
  bool get isMissing => food == null && estimate == null;

  Nutrition? get nutrition {
    if (food case final food?) return nutritionFor(food, grams);
    if (estimate case final guess?) {
      final factor = grams / 100;
      return (
        kcal: guess.kcalPer100 * factor,
        proteinG: guess.proteinPer100 * factor,
        carbG: guess.carbPer100 * factor,
        fatG: guess.fatPer100 * factor,
        fibreG: (guess.fibrePer100 ?? 0) * factor,
      );
    }
    return null;
  }
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
  var _pricing = false;
  var _saving = false;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  bool get _hasDraft => _name != null;

  int get _unmatched => _lines.where((l) => l.isMissing).length;
  int get _estimated => _lines.where((l) => l.isEstimate).length;

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

      await _priceTheRest(lines);
    } on QuickAddError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'The coach could not answer.');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// Asks the coach to price whatever the shelf could not answer.
  ///
  /// docs/MEAL-PLANNING.md §3, option three. Leaving these as zero was the
  /// worse answer: zero is definitely wrong, an estimate is approximately
  /// right, and only one of them says which it is.
  ///
  /// A failure here is not a failure of the recipe. The lines stay as gaps with
  /// a Find button, which is exactly where they were before.
  Future<void> _priceTheRest(List<_Line> lines) async {
    final missing = [for (final line in lines) if (line.isMissing) line];
    if (missing.isEmpty) return;

    setState(() => _pricing = true);
    try {
      final priced = await ref
          .read(draftServiceProvider)
          .estimate([for (final line in missing) line.name]);

      final byName = {
        for (final food in priced) food.name.trim().toLowerCase(): food,
      };
      if (!mounted) return;
      setState(() {
        for (final line in missing) {
          line.estimate = byName[line.name.trim().toLowerCase()];
        }
      });
    } catch (_) {
      // Nothing to say. The gaps are still gaps and still fixable by hand.
    } finally {
      if (mounted) setState(() => _pricing = false);
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
    final foods = ref.read(foodsRepositoryProvider);
    for (final line in _lines) {
      // An estimate becomes a real food row here and not a moment earlier, so
      // an abandoned draft leaves nothing behind. source = 'coach' is what lets
      // every screen afterwards keep calling it a guess.
      final food = line.food ??
          (line.estimate == null
              ? null
              : await foods.remember(line.estimate!.facts));
      if (food == null) continue;
      await repository.addIngredient(
        recipeId: id,
        foodId: food.id,
        quantityG: line.grams,
      );
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
                  ? _pricing
                      ? 'Pricing the ingredients you have not logged before…'
                      : 'Summed from your own foods, and from the coach where '
                          'you had none. Estimates are marked.'
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
                ? '1 ingredient could not be priced at all, so it counts as '
                    'nothing. Match it or the total is short.'
                : '$_unmatched ingredients could not be priced at all, so they '
                    'count as nothing. Match them or the total is short.',
            style: text.labelSmall?.copyWith(color: theme.colorScheme.error),
          ),
        ] else if (_estimated > 0) ...[
          const SizedBox(height: 4),
          Text(
            _estimated == 1
                ? '1 ingredient is a coach estimate. Tap it to swap in a food '
                    'you have weighed.'
                : '$_estimated ingredients are coach estimates. Tap one to '
                    'swap in a food you have weighed.',
            style: text.labelSmall?.copyWith(color: muted),
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
      title: Row(
        children: [
          Flexible(child: Text(line.food?.name ?? line.name)),
          // An estimate has to look like one on the row it is on, not only in
          // a summary underneath. This is the number somebody will weigh food
          // against next Sunday.
          if (line.isEstimate) ...[
            const SizedBox(width: 8),
            Icon(Icons.auto_awesome_outlined, size: 13, color: muted),
          ],
        ],
      ),
      subtitle: Text(
        macros == null
            ? ['Could not price it', ?line.note].join(' · ')
            : [
                if (line.isEstimate) 'Estimate',
                '${macros.kcal.round()} kcal',
                'P ${macros.proteinG.round()}',
                ?line.estimate?.note ?? line.note,
              ].join(' · '),
        style: text.labelSmall?.copyWith(
          color: macros == null ? theme.colorScheme.error : muted,
        ),
      ),
      trailing: macros == null
          ? TextButton(onPressed: onFind, child: const Text('Find'))
          : Text('${line.grams.round()} g', style: text.labelLarge),
      // An estimate stays tappable: swapping in a food you have actually
      // weighed is the upgrade path, and it should be one tap from the number
      // you doubt.
      onTap: onFind,
    );
  }
}

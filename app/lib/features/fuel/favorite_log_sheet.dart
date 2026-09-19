import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'meals_repository.dart';
import 'recipes_repository.dart';

/// Logs a saved favourite without going through the AI reader again —
/// the whole point of saving one. Each ingredient's amount is still a field,
/// not a fact: "2 eggs" yesterday can be "3 eggs" today without retyping the
/// rest of it.
Future<void> showFavoriteLogSheet(
  BuildContext context, {
  required String day,
  required RecipeDetail favorite,
  String slot = 'snack',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _FavoriteLogSheet(day: day, favorite: favorite, slot: slot),
    ),
  );
}

class _FavoriteLogSheet extends ConsumerStatefulWidget {
  const _FavoriteLogSheet({
    required this.day,
    required this.favorite,
    required this.slot,
  });

  final String day;
  final RecipeDetail favorite;
  final String slot;

  @override
  ConsumerState<_FavoriteLogSheet> createState() => _FavoriteLogSheetState();
}

class _FavoriteLogSheetState extends ConsumerState<_FavoriteLogSheet> {
  late String _slot = widget.slot;
  late final _grams = {
    for (final ingredient in widget.favorite.ingredients)
      ingredient.id: TextEditingController(
        text: ingredient.quantityG.round().toString(),
      ),
  };
  var _saving = false;

  @override
  void dispose() {
    for (final controller in _grams.values) {
      controller.dispose();
    }
    super.dispose();
  }

  double _enteredFor(String ingredientId) =>
      double.tryParse(_grams[ingredientId]!.text.trim()) ?? 0;

  Future<void> _log() async {
    if (_saving) return;
    setState(() => _saving = true);

    try {
      await ref
          .read(recipesRepositoryProvider)
          .logEachIngredient(
            widget.favorite,
            gramsByIngredientId: {
              for (final id in _grams.keys) id: _enteredFor(id),
            },
            slot: _slot,
            day: widget.day,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not log that: $e')));
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${widget.favorite.name}"?'),
        content: const Text(
          'It will stop showing up as a favourite. What you already logged '
          'with it stays.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(recipesRepositoryProvider).delete(widget.favorite.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    var kcal = 0.0;
    var protein = 0.0;
    for (final ingredient in widget.favorite.ingredients) {
      final grams = _enteredFor(ingredient.id);
      final scale = ingredient.quantityG <= 0
          ? 0
          : grams / ingredient.quantityG;
      kcal += ingredient.nutrition.kcal * scale;
      protein += ingredient.nutrition.proteinG * scale;
    }

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.favorite.name,
                      style: text.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Delete favourite',
                    onPressed: _delete,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              const SizedBox(height: 8),
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
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: [
                    for (final ingredient in widget.favorite.ingredients)
                      _IngredientRow(
                        name: ingredient.name,
                        controller: _grams[ingredient.id]!,
                        onChanged: () => setState(() {}),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${kcal.round()} kcal · P ${protein.round()} in total',
                textAlign: TextAlign.center,
                style: text.titleSmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _saving ? null : _log,
                child: Text(_saving ? 'Logging…' : 'Log it'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IngredientRow extends StatelessWidget {
  const _IngredientRow({
    required this.name,
    required this.controller,
    required this.onChanged,
  });

  final String name;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(name, style: text.bodyLarge)),
          const SizedBox(width: 8),
          SizedBox(
            width: 88,
            child: TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              textAlign: TextAlign.end,
              decoration: const InputDecoration(suffixText: 'g', isDense: true),
              onTap: () => controller.selection = TextSelection(
                baseOffset: 0,
                extentOffset: controller.text.length,
              ),
              onChanged: (_) => onChanged(),
            ),
          ),
        ],
      ),
    );
  }
}

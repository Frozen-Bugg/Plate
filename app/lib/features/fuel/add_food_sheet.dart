import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import 'food_search_service.dart';
import 'foods_repository.dart';
import 'meals_repository.dart';

/// Search what you already eat, pick an amount, log it.
///
/// Yours first, then Open Food Facts. What a lifter has eaten before answers
/// most searches instantly and offline; the online list is for the thing they
/// have not logged yet.
Future<void> showAddFoodSheet(
  BuildContext context, {
  required String day,
  String slot = 'snack',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _AddFoodSheet(day: day, slot: slot),
    ),
  );
}

class _AddFoodSheet extends ConsumerStatefulWidget {
  const _AddFoodSheet({required this.day, required this.slot});

  final String day;
  final String slot;

  @override
  ConsumerState<_AddFoodSheet> createState() => _AddFoodSheetState();
}

class _AddFoodSheetState extends ConsumerState<_AddFoodSheet> {
  final _search = TextEditingController();
  late String _slot = widget.slot;
  var _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final results = ref.watch(foodSearchProvider(_query)).value ?? const [];

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.82,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Log food', style: text.headlineSmall)),
                TextButton.icon(
                  onPressed: _newFood,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New'),
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
                      slot == 'snack' ? 'Snacks' : '${slot[0].toUpperCase()}${slot.substring(1)}',
                    ),
                  ),
              ],
              selected: {_slot},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _slot = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search your foods',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            Expanded(child: _results(context, results)),
          ],
        ),
      ),
    );
  }

  /// Yours first, then Open Food Facts.
  ///
  /// The order is the point. What a lifter has eaten before answers most
  /// searches instantly and offline; the online list is for the thing they have
  /// not logged yet, and it should never push the familiar answer down the
  /// screen while it loads.
  Widget _results(BuildContext context, List<Food> mine) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final online = ref.watch(onlineFoodSearchProvider(_query));
    final searching = _query.trim().length >= 2 && online.isLoading;
    final found = online.value ?? const <FoodFacts>[];

    // Anything already on the shelf is not offered again from the internet.
    final known = {for (final food in mine) ?food.barcode};
    final fresh = [
      for (final facts in found)
        if (facts.barcode == null || !known.contains(facts.barcode)) facts,
    ];

    if (mine.isEmpty && fresh.isEmpty && !searching) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _query.trim().isEmpty
                ? 'Nothing logged yet. Add the first food and it will be here '
                    'tomorrow.'
                : 'Nothing found, here or in Open Food Facts. "New" adds it '
                    'from the label.',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: muted),
          ),
        ),
      );
    }

    Widget heading(String label) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text(
            label.toUpperCase(),
            style: text.labelSmall?.copyWith(color: muted, letterSpacing: 1),
          ),
        );

    return ListView(
      children: [
        if (mine.isNotEmpty) ...[
          if (fresh.isNotEmpty || searching) heading('Yours'),
          for (final food in mine)
            ListTile(
              title: Text(food.name),
              subtitle: Text(
                [
                  ?food.brand,
                  '${food.kcalPer100.round()} kcal / 100 ${food.basis}',
                ].join(' · '),
                style: text.labelSmall?.copyWith(color: muted),
              ),
              trailing:
                  food.favourite ? const Icon(Icons.star, size: 18) : null,
              onTap: () => _pickQuantity(food),
            ),
        ],
        if (searching)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        if (fresh.isNotEmpty) ...[
          heading('Open Food Facts'),
          for (final facts in fresh)
            ListTile(
              title: Text(facts.name),
              subtitle: Text(
                [
                  ?facts.brand,
                  '${facts.kcalPer100.round()} kcal / 100 ${facts.basis}',
                ].join(' · '),
                style: text.labelSmall?.copyWith(color: muted),
              ),
              trailing: const Icon(Icons.south_west, size: 16),
              // Copied into the lifter's own foods on the way through, so the
              // next search finds it locally and offline.
              onTap: () => _logFromFacts(facts),
            ),
        ],
      ],
    );
  }

  Future<void> _logFromFacts(FoodFacts facts) async {
    final food = await ref.read(foodsRepositoryProvider).remember(facts);
    if (mounted) await _pickQuantity(food);
  }

  Future<void> _pickQuantity(Food food) async {
    final grams = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _QuantitySheet(food: food),
      ),
    );
    if (grams == null || !mounted) return;

    await ref.read(mealsRepositoryProvider).logFood(
          food: food,
          quantityG: grams,
          slot: _slot,
          day: widget.day,
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _newFood() async {
    final facts = await showModalBottomSheet<FoodFacts>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _NewFoodSheet(initialName: _search.text.trim()),
      ),
    );
    if (facts == null || !mounted) return;
    final food = await ref.read(foodsRepositoryProvider).remember(facts);
    if (mounted) await _pickQuantity(food);
  }
}

/// How much of it. Defaults to the food's own serving where it has one, because
/// "1 slice" is how people think and 34 g is how the database stores it.
class _QuantitySheet extends StatefulWidget {
  const _QuantitySheet({required this.food});

  final Food food;

  @override
  State<_QuantitySheet> createState() => _QuantitySheetState();
}

class _QuantitySheetState extends State<_QuantitySheet> {
  late final _controller = TextEditingController(
    text: (widget.food.servingG ?? 100).round().toString(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _grams =>
      double.tryParse(_controller.text.trim().replaceAll(',', '.')) ?? 0;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final food = widget.food;
    final macros = nutritionFor(food, _grams);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(food.name, style: text.headlineSmall),
            if (food.brand case final brand?)
              Text(brand, style: text.bodySmall?.copyWith(color: muted)),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              textAlign: TextAlign.center,
              style: text.displaySmall,
              decoration: InputDecoration(
                suffixText: food.basis,
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
            if (food.servingG case final serving?) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.center,
                child: TextButton(
                  onPressed: () => setState(
                    () => _controller.text = serving.round().toString(),
                  ),
                  child: Text(
                    food.servingLabel == null
                        ? '1 serving (${serving.round()} ${food.basis})'
                        : '${food.servingLabel} (${serving.round()} ${food.basis})',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '${macros.kcal.round()} kcal · P ${macros.proteinG.round()} · '
              'C ${macros.carbG.round()} · F ${macros.fatG.round()}',
              textAlign: TextAlign.center,
              style: text.titleMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _grams > 0 ? _save : null,
              child: const Text('Log it'),
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    if (_grams <= 0) return;
    Navigator.of(context).pop(_grams);
  }
}

/// A food typed off a label. The minimum a nutrition panel always carries:
/// a name, calories, and the three macros per 100.
class _NewFoodSheet extends StatefulWidget {
  const _NewFoodSheet({required this.initialName});

  final String initialName;

  @override
  State<_NewFoodSheet> createState() => _NewFoodSheetState();
}

class _NewFoodSheetState extends State<_NewFoodSheet> {
  late final _name = TextEditingController(text: widget.initialName);
  final _brand = TextEditingController();
  final _kcal = TextEditingController();
  final _protein = TextEditingController();
  final _carb = TextEditingController();
  final _fat = TextEditingController();
  final _serving = TextEditingController();

  @override
  void dispose() {
    for (final c in [_name, _brand, _kcal, _protein, _carb, _fat, _serving]) {
      c.dispose();
    }
    super.dispose();
  }

  double _value(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.')) ?? 0;

  bool get _valid => _name.text.trim().isNotEmpty && _value(_kcal) > 0;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    Widget number(String label, TextEditingController controller) => Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(labelText: label, isDense: true),
              onChanged: (_) => setState(() {}),
            ),
          ),
        );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New food', style: text.headlineSmall),
            const SizedBox(height: 4),
            Text('Per 100 g, straight off the label.',
                style: text.bodySmall?.copyWith(color: muted)),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _brand,
              decoration: const InputDecoration(labelText: 'Brand (optional)'),
            ),
            const SizedBox(height: 12),
            Row(children: [number('kcal', _kcal), number('Protein', _protein)]),
            const SizedBox(height: 12),
            Row(children: [number('Carbs', _carb), number('Fat', _fat)]),
            const SizedBox(height: 12),
            TextField(
              controller: _serving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Usual serving in grams (optional)',
                isDense: true,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _valid ? _save : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    final serving = _value(_serving);
    Navigator.of(context).pop(
      FoodFacts(
        name: _name.text.trim(),
        brand: _brand.text.trim().isEmpty ? null : _brand.text.trim(),
        kcalPer100: _value(_kcal),
        proteinPer100: _value(_protein),
        carbPer100: _value(_carb),
        fatPer100: _value(_fat),
        servingG: serving > 0 ? serving : null,
      ),
    );
  }
}

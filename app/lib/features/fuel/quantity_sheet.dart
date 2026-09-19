import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/db/app_database.dart';
import 'meals_repository.dart';

/// Asks how much, and returns it in grams — or null if the sheet was dismissed.
///
/// Used for correcting an amount already logged: "150 g, actually make that
/// 200".
Future<double?> showQuantitySheet(
  BuildContext context, {
  required Food food,
  double? initialGrams,
  String cta = 'Save',
}) {
  return showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _QuantitySheet(food: food, initial: initialGrams, cta: cta),
    ),
  );
}

/// How much of it. Defaults to the food's own serving where it has one, because
/// "1 slice" is how people think and 34 g is how the database stores it.
class _QuantitySheet extends StatefulWidget {
  const _QuantitySheet({required this.food, this.initial, this.cta = 'Log it'});

  final Food food;
  final double? initial;
  final String cta;

  @override
  State<_QuantitySheet> createState() => _QuantitySheetState();
}

class _QuantitySheetState extends State<_QuantitySheet> {
  late final _controller = TextEditingController(
    text: _trim(widget.initial ?? widget.food.servingG ?? 100),
  );
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The field opens with a number already in it, so focusing it without
    // selecting it means the first digit typed lands next to that number: 100
    // becomes 1005 rather than 5. Selecting it makes typing a replacement,
    // which is what someone who opened the keyboard meant to do.
    _focus.addListener(_selectAllOnFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _selectAllOnFocus() {
    if (!_focus.hasFocus) return;
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _focus.removeListener(_selectAllOnFocus);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  static String _trim(double value) {
    final rounded = (value * 10).round() / 10;
    return rounded == rounded.roundToDouble()
        ? rounded.toStringAsFixed(0)
        : '$rounded';
  }

  double get _grams =>
      double.tryParse(_controller.text.trim().replaceAll(',', '.')) ?? 0;

  void _set(double grams) => setState(() {
    _controller.text = _trim(grams < 0 ? 0 : grams);
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  });

  /// The amounts worth one tap.
  ///
  /// The food's own serving first where it has one — most packaged things do,
  /// and it is nearly always the answer — then round numbers around whatever is
  /// currently in the box, so a correction is also one tap.
  List<double> get _shortcuts {
    final serving = widget.food.servingG;
    return {
      ?serving,
      if (serving != null) serving * 2,
      50.0,
      100.0,
      150.0,
      200.0,
    }.toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final food = widget.food;
    final macros = nutritionFor(food, _grams);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(food.name, style: text.headlineSmall),
            Text(
              [
                ?food.brand,
                '${food.kcalPer100.round()} kcal / 100 ${food.basis}',
              ].join(' · '),
              style: text.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                _Nudge(
                  icon: Icons.remove,
                  label: 'Less',
                  onPressed: () => _set(_grams - 10),
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    textAlign: TextAlign.center,
                    style: text.displaySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      suffixText: food.basis,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _save(),
                  ),
                ),
                _Nudge(
                  icon: Icons.add,
                  label: 'More',
                  onPressed: () => _set(_grams + 10),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final amount in _shortcuts)
                  ActionChip(
                    label: Text(_labelFor(amount)),
                    onPressed: () => _set(amount),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '${macros.kcal.round()} kcal · P ${macros.proteinG.round()} · '
              'C ${macros.carbG.round()} · F ${macros.fatG.round()}',
              textAlign: TextAlign.center,
              style: text.titleMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _grams > 0 ? _save : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: Text(widget.cta),
            ),
          ],
        ),
      ),
    );
  }

  /// A shortcut says what it means where the food knows: "1 slice" beats 34 g.
  String _labelFor(double amount) {
    final food = widget.food;
    final serving = food.servingG;
    if (serving != null && food.servingLabel != null) {
      if (amount == serving) return food.servingLabel!;
      if (amount == serving * 2) return '2 × ${food.servingLabel}';
    }
    if (serving != null && amount == serving) return '1 serving';
    return '${_trim(amount)} ${food.basis}';
  }

  void _save() {
    if (_grams <= 0) return;
    Navigator.of(context).pop(_grams);
  }
}

class _Nudge extends StatelessWidget {
  const _Nudge({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      onPressed: onPressed,
      icon: Icon(icon),
      tooltip: label,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
  }
}

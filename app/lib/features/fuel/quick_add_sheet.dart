import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'foods_repository.dart';
import 'meals_repository.dart';
import 'quick_add_service.dart';

/// Say or type what you ate, correct what it got wrong, log it.
///
/// The confirm step is not politeness. Every number here was estimated by a
/// model from a sentence, and docs/PLAN.md §11 requires an estimate to be
/// itemised and editable and never logged on the model's say-so. So the sheet
/// shows each food separately with what it assumed, and the amount is a field
/// rather than a fact.
Future<void> showQuickAddSheet(
  BuildContext context, {
  required String day,
  String slot = 'snack',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _QuickAddSheet(day: day, slot: slot),
    ),
  );
}

class _QuickAddSheet extends ConsumerStatefulWidget {
  const _QuickAddSheet({required this.day, required this.slot});

  final String day;
  final String slot;

  @override
  ConsumerState<_QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends ConsumerState<_QuickAddSheet> {
  final _text = TextEditingController();
  final _speech = SpeechToText();

  late String _slot = widget.slot;
  ParsedMeal? _parsed;
  String? _error;
  var _busy = false;
  var _listening = false;
  var _saving = false;

  @override
  void dispose() {
    _text.dispose();
    // Stops the microphone if the sheet is dismissed mid-sentence.
    _speech.stop();
    super.dispose();
  }

  /// Dictation, on the device.
  ///
  /// `speech_to_text` uses the platform recogniser, so on most Android phones
  /// nothing is sent anywhere — and the words land in the same box as typing,
  /// so they can be corrected before they cost a model call.
  Future<void> _listen() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }

    final available = await _speech.initialize(
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'done' || status == 'notListening') {
          setState(() => _listening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _listening = false);
      },
    );

    if (!mounted) return;
    if (!available) {
      setState(() {
        _error = 'This phone will not let Overload use the microphone. '
            'Allow it in Settings → Apps → Overload → Permissions, or type '
            'it instead.';
      });
      return;
    }

    setState(() {
      _listening = true;
      _error = null;
    });
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() {
          _text.text = result.recognizedWords;
          _text.selection =
              TextSelection.collapsed(offset: _text.text.length);
        });
      },
      listenOptions: SpeechListenOptions(partialResults: true),
    );
  }

  Future<void> _parse() async {
    final said = _text.text.trim();
    if (said.isEmpty || _busy) return;
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final meal = await ref
          .read(quickAddServiceProvider)
          .parse(said, slot: _slot);
      if (!mounted) return;
      setState(() {
        _parsed = meal;
        _slot = meal.slot;
        // Nothing found is not an error, it is an answer — and one the lifter
        // can act on by rewording rather than by retrying.
        _error = meal.items.isEmpty
            ? 'No food in that. Try "200g chicken and a cup of rice".'
            : null;
      });
    } on QuickAddError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Writes what is on screen, not what the model said.
  ///
  /// Each item becomes a `Food` row and a logged item, so the second time this
  /// food is eaten it is already on the lifter's own shelf — searchable,
  /// offline, and with whatever correction was made here baked in.
  Future<void> _save() async {
    final meal = _parsed;
    if (meal == null || _saving) return;
    setState(() => _saving = true);

    final foods = ref.read(foodsRepositoryProvider);
    final meals = ref.read(mealsRepositoryProvider);

    try {
      for (final item in meal.items) {
        if (item.grams <= 0) continue;
        final food = await foods.remember(
          FoodFacts(
            name: item.name,
            // Where the *food* came from: the coach estimated it. How it was
            // logged — by voice — is recorded on the meal item below. Two
            // different questions, and `foods.source` does not accept 'voice'.
            source: 'coach',
            kcalPer100: item.kcalPer100,
            proteinPer100: item.proteinPer100,
            carbPer100: item.carbPer100,
            fatPer100: item.fatPer100,
            servingG: item.grams,
          ),
        );
        await meals.logFood(
          food: food,
          quantityG: item.grams,
          slot: _slot,
          day: widget.day,
          source: 'voice',
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save that: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final meal = _parsed;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Say what you ate', style: text.headlineSmall),
              const SizedBox(height: 4),
              Text(
                'Everything below is an estimate. Check it before it is saved.',
                style: text.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 12),

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

              TextField(
                controller: _text,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                enabled: !_busy,
                decoration: InputDecoration(
                  hintText: '4 eggs and 2 high protein sandwiches',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _listening ? 'Stop' : 'Dictate',
                    onPressed: _busy ? null : _listen,
                    icon: Icon(
                      _listening ? Icons.stop_circle : Icons.mic_none,
                      color: _listening ? theme.colorScheme.error : null,
                    ),
                  ),
                ),
                onChanged: (_) {
                  // A new sentence invalidates the old reading.
                  if (_parsed != null) setState(() => _parsed = null);
                },
              ),
              if (_listening)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Listening…',
                    style: text.labelSmall?.copyWith(color: theme.colorScheme.error),
                  ),
                ),

              const SizedBox(height: 10),
              FilledButton(
                onPressed: _busy ? null : _parse,
                child: Text(_busy ? 'Reading…' : 'Read it'),
              ),

              if (_error case final message?) ...[
                const SizedBox(height: 10),
                Text(
                  message,
                  style: text.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ],

              const SizedBox(height: 12),
              Expanded(
                child: meal == null || meal.items.isEmpty
                    ? const SizedBox.shrink()
                    : ListView(
                        children: [
                          for (final item in meal.items)
                            _ItemRow(
                              item: item,
                              onChanged: () => setState(() {}),
                            ),
                          const SizedBox(height: 8),
                          _Total(meal: meal),
                        ],
                      ),
              ),

              if (meal != null && meal.items.isNotEmpty)
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.check),
                  label: Text(
                    _saving
                        ? 'Saving…'
                        : 'Log ${meal.items.length} '
                            '${meal.items.length == 1 ? 'item' : 'items'}',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One food, with its amount editable.
///
/// Grams is the field on purpose: it is what the schema stores, and changing
/// it rescales the calories and macros, so a lifter who knows it was 3 eggs
/// rather than 4 fixes everything by fixing one number.
class _ItemRow extends StatefulWidget {
  const _ItemRow({required this.item, required this.onChanged});

  final ParsedItem item;
  final VoidCallback onChanged;

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  late final _grams =
      TextEditingController(text: widget.item.grams.round().toString());

  @override
  void dispose() {
    _grams.dispose();
    super.dispose();
  }

  double get _entered => double.tryParse(_grams.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final item = widget.item;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.name, style: text.titleSmall),
                      Text(
                        item.said,
                        style: text.labelSmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _grams,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(
                      suffixText: 'g',
                      isDense: true,
                    ),
                    onTap: () => _grams.selection = TextSelection(
                      baseOffset: 0,
                      extentOffset: _grams.text.length,
                    ),
                    onChanged: (_) {
                      widget.item.grams = _entered;
                      setState(() {});
                      widget.onChanged();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${item.scaledKcal.round()} kcal · '
              'P ${item.scaledProteinG.round()} · '
              'C ${item.scaledCarbG.round()} · '
              'F ${item.scaledFatG.round()}',
              style: text.labelMedium,
            ),
            // The assumption, where there was one worth arguing with.
            if (item.note case final note?) ...[
              const SizedBox(height: 4),
              Text(
                note,
                style: text.labelSmall?.copyWith(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.meal});

  final ParsedMeal meal;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    var kcal = 0.0;
    var protein = 0.0;

    for (final item in meal.items) {
      kcal += item.scaledKcal;
      protein += item.scaledProteinG;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '${kcal.round()} kcal · P ${protein.round()} in total',
        textAlign: TextAlign.center,
        style: text.titleSmall,
      ),
    );
  }
}

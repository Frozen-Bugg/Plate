import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'ai_style.dart';
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

  /// [_parsed]'s items, each checked against the shelf. This is what the
  /// sheet actually renders and saves — see [MatchedItem] for why a name
  /// match beats the model's own guess whenever one exists.
  List<MatchedItem>? _matched;
  String? _error;
  var _busy = false;
  var _listening = false;
  var _saving = false;

  /// Looks every parsed item up against the lifter's own foods before
  /// showing anything. The fifth "4 eggs" should reuse the food the first
  /// one made — corrections and all — rather than asking the model to
  /// re-guess a number that is already known.
  Future<List<MatchedItem>> _matchAgainstShelf(ParsedMeal meal) async {
    final foods = ref.read(foodsRepositoryProvider);
    final matched = <MatchedItem>[];
    for (final item in meal.items) {
      final row = MatchedItem(item);
      row.matchedFood = await foods.bestMatch(item.name);
      matched.add(row);
    }
    return matched;
  }

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
        _error =
            'This phone will not let Overload use the microphone. '
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
          _text.selection = TextSelection.collapsed(offset: _text.text.length);
        });
      },
      listenOptions: SpeechListenOptions(partialResults: true),
    );
  }

  /// Photograph a plate or a label and let the coach read it.
  ///
  /// Resized before it leaves the phone. A modern camera produces a 4 MB
  /// picture, which is slow to upload, expensive to send and no more accurate
  /// than a 1024 px one — the coach is judging portions, not reading serial
  /// numbers. The exception is a nutrition label, which is why it is not
  /// shrunk further.
  Future<void> _photograph(ImageSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 80,
    );
    if (picked == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _parsed = null;
      _matched = null;
    });

    try {
      final bytes = await picked.readAsBytes();
      final meal = await ref
          .read(quickAddServiceProvider)
          .parsePhoto(
            bytes: bytes,
            // pickImage gives JPEG for a camera shot and keeps the original
            // format for a gallery pick.
            mediaType: picked.path.toLowerCase().endsWith('.png')
                ? 'image/png'
                : 'image/jpeg',
            slot: _slot,
            note: _text.text,
          );
      final matched = await _matchAgainstShelf(meal);
      if (!mounted) return;
      setState(() {
        _parsed = meal;
        _matched = matched;
        _slot = meal.slot;
        _error = meal.items.isEmpty
            ? 'No food found in that picture. Try a clearer shot, or type it.'
            : null;
      });
    } on QuickAddError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickPhotoSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              subtitle: const Text('A plate, or the nutrition label'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose one'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source != null && mounted) await _photograph(source);
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
      final matched = await _matchAgainstShelf(meal);
      if (!mounted) return;
      setState(() {
        _parsed = meal;
        _matched = matched;
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
    final matched = _matched;
    if (matched == null || _saving) return;
    setState(() => _saving = true);

    final foods = ref.read(foodsRepositoryProvider);
    final meals = ref.read(mealsRepositoryProvider);

    try {
      for (final row in matched) {
        if (row.grams <= 0) continue;
        // Already on the shelf: log against the real row, corrections and
        // all, rather than writing the model's guess over it. Only when
        // nothing matched does the guess become a new food.
        final food =
            row.matchedFood ??
            await foods.remember(
              FoodFacts(
                name: row.name,
                // Where the *food* came from: the coach estimated it. How it
                // was logged — by voice — is recorded on the meal item below.
                // Two different questions, and `foods.source` does not
                // accept 'voice'.
                source: 'coach',
                kcalPer100: row.kcalPer100,
                proteinPer100: row.proteinPer100,
                carbPer100: row.carbPer100,
                fatPer100: row.fatPer100,
                servingG: row.grams,
              ),
            );
        await meals.logFood(
          food: food,
          quantityG: row.grams,
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
    final matched = _matched;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AiSheetHeader(
              title: 'Tell me what you had',
              subtitle: matched == null
                  ? 'Say it, type it, or photograph it'
                  : 'Check it, then log it — nothing saves on its own',
              busy: _busy,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
                      onSelectionChanged: (s) =>
                          setState(() => _slot = s.first),
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
                        helperText:
                            'Or photograph it — a note here helps with '
                            'anything the camera cannot judge.',
                        helperMaxLines: 2,
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
                        if (_parsed != null) {
                          setState(() {
                            _parsed = null;
                            _matched = null;
                          });
                        }
                      },
                    ),
                    if (_listening)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Listening…',
                          style: text.labelSmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),

                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: _busy ? null : _parse,
                            child: Text(_busy ? 'Reading…' : 'Read it'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          tooltip: 'Photograph a plate or a label',
                          onPressed: _busy ? null : _pickPhotoSource,
                          icon: const Icon(Icons.photo_camera_outlined),
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                        ),
                      ],
                    ),

                    if (_error case final message?) ...[
                      const SizedBox(height: 10),
                      Text(
                        message,
                        style: text.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),
                    if (_busy && (matched?.isEmpty ?? true))
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: AiThinking(label: 'Reading what you said…'),
                      )
                    else if (matched != null && matched.isNotEmpty) ...[
                      for (final (i, row) in matched.indexed)
                        AiReveal(
                          index: i,
                          child: _MatchedItemRow(
                            row: row,
                            onChanged: () => setState(() {}),
                          ),
                        ),
                      const SizedBox(height: 4),
                      AiReveal(
                        index: matched.length,
                        child: _Total(items: matched),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (matched != null && matched.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.check),
                  label: Text(
                    _saving
                        ? 'Saving…'
                        : 'Log ${matched.length} '
                              '${matched.length == 1 ? 'item' : 'items'}',
                  ),
                ),
              ),
          ],
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
class _MatchedItemRow extends StatefulWidget {
  const _MatchedItemRow({required this.row, required this.onChanged});

  final MatchedItem row;
  final VoidCallback onChanged;

  @override
  State<_MatchedItemRow> createState() => _MatchedItemRowState();
}

class _MatchedItemRowState extends State<_MatchedItemRow> {
  late final _grams = TextEditingController(
    text: widget.row.grams.round().toString(),
  );

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
    final row = widget.row;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        // A hairline of the accent down the side rather than a plain card —
        // enough to say "the coach touched this row" without a border around
        // every single one shouting it.
        border: Border(
          left: BorderSide(
            color: row.isFromShelf
                ? theme.colorScheme.outlineVariant
                : aiAccent(context).withValues(alpha: 0.6),
            width: 3,
          ),
        ),
      ),
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
                      Text(row.name, style: text.titleSmall),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            row.said,
                            style: text.labelSmall?.copyWith(color: muted),
                          ),
                          row.isFromShelf
                              ? const AiTag.fromShelf()
                              : const AiTag.estimate(),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 88,
                  child: TextField(
                    controller: _grams,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
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
                      row.grams = _entered;
                      setState(() {});
                      widget.onChanged();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${row.scaledKcal.round()} kcal · '
              'P ${row.scaledProteinG.round()} · '
              'C ${row.scaledCarbG.round()} · '
              'F ${row.scaledFatG.round()}',
              style: text.labelMedium,
            ),
            // The assumption, where there was one worth arguing with. Not
            // shown once a shelf match is in play — the note was the model's
            // hedge about its own guess, and there is no guess any more.
            if (!row.isFromShelf && row.note != null) ...[
              const SizedBox(height: 4),
              Text(row.note!, style: text.labelSmall?.copyWith(color: muted)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.items});

  final List<MatchedItem> items;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    var kcal = 0.0;
    var protein = 0.0;

    for (final item in items) {
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

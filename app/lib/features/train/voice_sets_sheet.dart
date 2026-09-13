import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../core/db/app_database.dart';
import '../fuel/quick_add_service.dart';
import 'exercises_repository.dart';
import 'logging_repository.dart';

/// "Three by eight at eighty on bench, RPE 8" — logged after you confirm it.
///
/// The same shape as the food quick-add, for the same reason: every number
/// came out of a model reading a sentence, so it is shown itemised and
/// editable and written only once the lifter agrees.
///
/// One extra job here that food does not have — the exercise has to be matched
/// to a real row before anything can be logged against it, and a near miss
/// ("bench" for "Bench Press") is the normal case rather than the exception.
Future<void> showVoiceSetsSheet(
  BuildContext context, {
  required String sessionId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _VoiceSetsSheet(sessionId: sessionId),
    ),
  );
}

class _VoiceSetsSheet extends ConsumerStatefulWidget {
  const _VoiceSetsSheet({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_VoiceSetsSheet> createState() => _VoiceSetsSheetState();
}

class _VoiceSetsSheetState extends ConsumerState<_VoiceSetsSheet> {
  final _text = TextEditingController();
  final _speech = SpeechToText();

  List<ParsedSet>? _parsed;
  String? _error;
  var _busy = false;
  var _listening = false;
  var _saving = false;

  @override
  void dispose() {
    _text.dispose();
    _speech.stop();
    super.dispose();
  }

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
      setState(() => _error =
          'This phone will not let Overload use the microphone. Type it '
          'instead, or allow it in Settings → Apps → Overload.');
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
      final sets = await ref.read(quickAddServiceProvider).parseSets(said);
      if (!mounted) return;
      setState(() {
        _parsed = sets;
        _error = sets.isEmpty
            ? 'No sets in that. Try "three by eight at eighty on bench".'
            : null;
      });
    } on QuickAddError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The library row this set belongs to, or null when nothing matches.
  ///
  /// Exact name first, then a loose contains — "bench" finds "Bench Press",
  /// which is what a lifter says out loud. An unmatched name is shown as such
  /// rather than logged against a guess.
  Exercise? _match(String said) {
    final library = ref.read(exerciseLibraryProvider).value ?? const [];
    final needle = said.trim().toLowerCase();
    if (needle.isEmpty) return null;

    for (final exercise in library) {
      if (exercise.name.toLowerCase() == needle) return exercise;
    }
    final loose = library
        .where((e) =>
            e.name.toLowerCase().contains(needle) ||
            needle.contains(e.name.toLowerCase()))
        .toList();
    // Only when it is unambiguous. Two matches means the lifter should pick.
    return loose.length == 1 ? loose.first : null;
  }

  Future<void> _save() async {
    final parsed = _parsed;
    if (parsed == null || _saving) return;
    setState(() => _saving = true);

    final logging = ref.read(loggingRepositoryProvider);
    final exercises = ref.read(exercisesRepositoryProvider);

    try {
      // Which session exercise each movement belongs to, made once and reused
      // so three sets of bench land under one heading rather than three.
      final blocks = <String, String>{};
      for (final set in parsed) {
        final matched = _match(set.exercise) ??
            // Nothing in the library said it. Adding it is better than
            // refusing: the lifter clearly did the movement, and a custom
            // exercise is one row.
            await exercises.create(name: set.exercise);

        final blockId = blocks[matched.id] ??= await logging.addExercise(
          sessionId: widget.sessionId,
          exerciseId: matched.id,
        );

        for (var i = 0; i < set.sets; i++) {
          await logging.logSet(
            sessionExerciseId: blockId,
            exerciseId: matched.id,
            weightKg: set.weightKg,
            reps: set.reps,
            rir: set.rir,
          );
        }
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not log that: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final parsed = _parsed;
    final total = parsed?.fold<int>(0, (t, s) => t + s.sets) ?? 0;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Say your sets', style: text.headlineSmall),
              const SizedBox(height: 4),
              Text(
                'Check them before they are logged.',
                style: text.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 12),

              TextField(
                controller: _text,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                enabled: !_busy,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'three by eight at eighty on bench, RPE 8',
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
                  if (_parsed != null) setState(() => _parsed = null);
                },
              ),
              if (_listening)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Listening…',
                      style: text.labelSmall
                          ?.copyWith(color: theme.colorScheme.error)),
                ),

              const SizedBox(height: 10),
              FilledButton(
                onPressed: _busy ? null : _parse,
                child: Text(_busy ? 'Reading…' : 'Read it'),
              ),

              if (_error case final message?) ...[
                const SizedBox(height: 10),
                Text(message,
                    style: text.bodySmall
                        ?.copyWith(color: theme.colorScheme.error)),
              ],

              const SizedBox(height: 12),
              Expanded(
                child: parsed == null || parsed.isEmpty
                    ? const SizedBox.shrink()
                    : ListView(
                        children: [
                          for (final set in parsed) _SetRow(set: set, match: _match),
                        ],
                      ),
              ),

              if (parsed != null && parsed.isNotEmpty)
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.check),
                  label: Text(
                    _saving ? 'Logging…' : 'Log $total ${total == 1 ? 'set' : 'sets'}',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SetRow extends StatelessWidget {
  const _SetRow({required this.set, required this.match});

  final ParsedSet set;
  final Exercise? Function(String) match;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final matched = match(set.exercise);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(matched?.name ?? set.exercise),
        subtitle: Text(
          [
            '${set.sets} × ${set.reps} @ ${_trim(set.weightKg)} kg',
            if (set.rir case final rir?) 'RIR ${_trim(rir)}',
            // Said plainly rather than hidden: a new exercise appearing in the
            // library is a thing the lifter should know is about to happen.
            if (matched == null) 'new exercise — will be added',
          ].join(' · '),
          style: text.labelSmall?.copyWith(
            color: matched == null ? theme.colorScheme.primary : muted,
          ),
        ),
      ),
    );
  }

  static String _trim(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
}

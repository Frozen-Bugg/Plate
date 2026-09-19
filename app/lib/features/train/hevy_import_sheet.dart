import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import 'exercises_repository.dart';
import 'hevy_import.dart';
import 'logging_repository.dart';
import 'progression_repository.dart';
import 'sessions_repository.dart';

/// Paste a workout copied out of Hevy and log it into history.
///
/// This is how a workout gets into Overload now — see hevy_import.dart for
/// why. Parsing is instant and offline; nothing is written until the
/// itemised read-back is confirmed, the same rule every other place in this
/// app that turns text into logged numbers follows.
Future<void> showHevyImportSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: const _HevyImportSheet(),
    ),
  );
}

class _HevyImportSheet extends ConsumerStatefulWidget {
  const _HevyImportSheet();

  @override
  ConsumerState<_HevyImportSheet> createState() => _HevyImportSheetState();
}

class _HevyImportSheetState extends ConsumerState<_HevyImportSheet> {
  final _text = TextEditingController();
  ParsedHevyWorkout? _parsed;
  String? _error;
  var _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _read() {
    try {
      final workout = parseHevyWorkout(_text.text);
      setState(() {
        _parsed = workout;
        _error = null;
      });
    } on HevyParseError catch (e) {
      setState(() {
        _parsed = null;
        _error = e.message;
      });
    }
  }

  Future<void> _log() async {
    final workout = _parsed;
    if (workout == null || _saving) return;
    setState(() => _saving = true);

    try {
      await importHevyWorkout(
        workout,
        exercises: ref.read(exercisesRepositoryProvider),
        sessions: ref.read(sessionsRepositoryProvider),
        logging: ref.read(loggingRepositoryProvider),
        progression: ref.read(progressionRepositoryProvider),
      );
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
    final parsed = _parsed;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Paste from Hevy', style: text.headlineSmall),
            const SizedBox(height: 4),
            Text(
              parsed == null
                  ? 'In Hevy: open the workout, tap Share, then Copy. Paste '
                        'it below.'
                  : 'Check it, then log it.',
              style: text.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            if (parsed == null)
              Expanded(
                child: TextField(
                  controller: _text,
                  autofocus: true,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    hintText:
                        'Incline Bench Press (Dumbbell)\n'
                        'Set 1: 30 kg x 9\n'
                        'Set 2: 30 kg x 8\n\n'
                        'Chest Dip\nSet 1: 18 reps',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
              )
            else
              Expanded(child: _Preview(workout: parsed)),
            if (_error case final message?) ...[
              const SizedBox(height: 10),
              Text(
                message,
                style: text.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            if (parsed == null)
              FilledButton(onPressed: _read, child: const Text('Read it'))
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                              _parsed = null;
                              _error = null;
                            }),
                      child: const Text('Edit'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving ? null : _log,
                      child: Text(_saving ? 'Logging…' : 'Log it'),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.workout});

  final ParsedHevyWorkout workout;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final startedAt = workout.startedAt;

    return ListView(
      children: [
        if (workout.title case final title?)
          Text(title, style: text.titleMedium),
        Text(
          startedAt == null
              ? 'No date in that paste — logged as just now.'
              : '${formatDay(startedAt.toUtc())} · '
                    '${formatTime(startedAt.toUtc())}',
          style: text.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: 12),
        for (final exercise in workout.exercises)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(exercise.name, style: text.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    exercise.sets
                        .map(
                          (s) => s.weightKg == null
                              ? '${s.reps} reps'
                              : '${formatWeight(s.weightKg!)} × ${s.reps}',
                        )
                        .join('   '),
                    style: text.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

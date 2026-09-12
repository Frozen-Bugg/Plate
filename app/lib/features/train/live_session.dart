import 'package:engine/engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/db/app_database.dart';
import '../../core/format.dart';
import 'exercise_picker.dart';
import 'exercises_repository.dart';
import 'logging_repository.dart';
import 'progression_repository.dart';
import 'rest_timer.dart';
import 'templates_repository.dart';

/// The exercises in the running session, each with its logged sets and a row
/// for adding the next one.
class LiveSessionExercises extends ConsumerWidget {
  const LiveSessionExercises({super.key, required this.sessionId});

  final String sessionId;

  Future<void> _pickExercise(BuildContext context, WidgetRef ref) async {
    final chosen = await showExercisePicker(context);
    if (chosen == null) return;
    await ref
        .read(loggingRepositoryProvider)
        .addExercise(sessionId: sessionId, exerciseId: chosen.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exercises = ref.watch(sessionExercisesProvider(sessionId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...?exercises.value?.map(
          (e) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ExerciseBlock(sessionExercise: e),
          ),
        ),
        OutlinedButton.icon(
          onPressed: () => _pickExercise(context, ref),
          icon: const Icon(Icons.add, size: 20),
          label: const Text('Add exercise'),
        ),
      ],
    );
  }
}

/// One exercise: what the engine wants this time, what has been logged, and
/// the row for logging the next set.
class _ExerciseBlock extends ConsumerWidget {
  const _ExerciseBlock({required this.sessionExercise});

  final SessionExercise sessionExercise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final setsAsync = ref.watch(setsProvider(sessionExercise.id));
    final sets = setsAsync.value ?? const <WorkoutSet>[];
    final target =
        ref.watch(progressionStateProvider(sessionExercise.exerciseId)).value;
    final planned =
        ref.watch(prescriptionProvider(sessionExercise.exerciseId)).value?.sets;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _ExerciseName(exerciseId: sessionExercise.exerciseId),
              ),
              if (planned != null)
                _SetCount(done: sets.length, planned: planned),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => ref
                    .read(loggingRepositoryProvider)
                    .removeExercise(sessionExercise.id),
              ),
            ],
          ),
          if (target?.nextLoadKg case final load?) ...[
            Text(
              // The engine decided this last time; the screen only shows it.
              'Target ${formatWeight(load)} x ${target?.nextReps ?? '-'}'
              '${(target?.stallCount ?? 0) >= 3 ? '  ·  stalled' : ''}',
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            _Plates(targetKg: load),
            const SizedBox(height: 8),
          ],
          // Never swallow a failure here: a set that was logged but cannot be
          // read back must say so, not render as an empty list.
          if (setsAsync case AsyncError(:final error))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                "Couldn't read the sets for this exercise.\n$error",
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ),
          for (final set in sets)
            _SetRow(set: set, onDelete: () {
              ref.read(loggingRepositoryProvider).deleteSet(set.id);
            }),
          _AddSetRow(
            sessionExerciseId: sessionExercise.id,
            exerciseId: sessionExercise.exerciseId,
            suggestedLoad: target?.nextLoadKg,
            suggestedReps: target?.nextReps,
            lastSet: sets.isEmpty ? null : sets.last,
          ),
          RestTimerBar(exerciseId: sessionExercise.exerciseId),
        ],
      ),
    );
  }
}

class _ExerciseName extends ConsumerWidget {
  const _ExerciseName({required this.exerciseId});

  final String exerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Text(
      ref.watch(exerciseByIdProvider(exerciseId))?.name ?? 'Exercise',
      style: Theme.of(context).textTheme.titleMedium,
    );
  }
}

class _SetRow extends StatelessWidget {
  const _SetRow({required this.set, required this.onDelete});

  final WorkoutSet set;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weight = set.weightKg;
    final reps = set.reps;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '${set.setIndex + 1}',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              weight == null || reps == null
                  ? '—'
                  : '${formatWeight(weight)} x $reps'
                      '${set.rir == null ? '' : '  @${formatRir(set.rir!)}'}',
              style: theme.textTheme.bodyLarge,
            ),
          ),
          if (set.isPr)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'PR',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: PillarColors.of(context).move,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          if (set.e1rmKg case final e?)
            Text(
              'e1RM ${formatWeight(e)}',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          IconButton(
            tooltip: 'Delete set',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// Weight, reps and optional RIR, then Log.
///
/// The fields hold real values rather than hints, and keep whatever was just
/// logged. Straight sets — which is most of them — are one tap on Log, and a
/// change is a tap on plus or minus rather than a keyboard, a select-all and a
/// retype with chalk on your hands.
///
/// The old version left the fields empty and showed the target as placeholder
/// text, with "empty means the hint" as invisible logic. It read as a form
/// waiting to be filled in, and half of it had to be filled in every set.
class _AddSetRow extends ConsumerStatefulWidget {
  const _AddSetRow({
    required this.sessionExerciseId,
    required this.exerciseId,
    this.suggestedLoad,
    this.suggestedReps,
    this.lastSet,
  });

  final String sessionExerciseId;
  final String exerciseId;
  final double? suggestedLoad;
  final int? suggestedReps;
  final WorkoutSet? lastSet;

  @override
  ConsumerState<_AddSetRow> createState() => _AddSetRowState();
}

class _AddSetRowState extends ConsumerState<_AddSetRow> {
  final _weight = TextEditingController();
  final _reps = TextEditingController();
  final _rir = TextEditingController();
  String? _error;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  @override
  void didUpdateWidget(_AddSetRow old) {
    super.didUpdateWidget(old);
    // The engine's target arrives asynchronously, and the previous set arrives
    // when it is written. Fill in whatever is still blank, but never overwrite
    // something the lifter has typed.
    _prefill(onlyEmpty: true);
  }

  void _prefill({bool onlyEmpty = false}) {
    final weight = widget.lastSet?.weightKg ?? widget.suggestedLoad;
    final reps = widget.lastSet?.reps ?? widget.suggestedReps;
    if (weight != null && (!onlyEmpty || _weight.text.isEmpty)) {
      _weight.text = _trim(weight);
    }
    if (reps != null && (!onlyEmpty || _reps.text.isEmpty)) {
      _reps.text = '$reps';
    }
  }

  @override
  void dispose() {
    _weight.dispose();
    _reps.dispose();
    _rir.dispose();
    super.dispose();
  }

  static String _trim(double value) {
    final rounded = (value * 100).round() / 100;
    return rounded == rounded.roundToDouble()
        ? rounded.toStringAsFixed(0)
        : '$rounded';
  }

  static double? _parse(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  /// The jump this equipment makes. A machine's pin does not move in 1.25s.
  double get _loadStep =>
      ref.read(exerciseByIdProvider(widget.exerciseId))?.loadStepKg ?? 2.5;

  void _nudgeWeight(double by) {
    final current = _parse(_weight) ?? widget.suggestedLoad ?? 0;
    final next = current + by;
    setState(() => _weight.text = _trim(next < 0 ? 0 : next));
  }

  void _nudgeReps(int by) {
    final current = int.tryParse(_reps.text.trim()) ?? widget.suggestedReps ?? 0;
    final next = current + by;
    setState(() => _reps.text = '${next < 1 ? 1 : next}');
  }

  Future<void> _log() async {
    final weight = _parse(_weight);
    final reps = int.tryParse(_reps.text.trim());
    final rir = _rir.text.trim().isEmpty ? null : _parse(_rir);

    if (weight == null || reps == null || reps < 1) {
      setState(() => _error = 'Enter a weight and at least one rep');
      return;
    }
    // Tapping Log twice in the half-second before the row rebuilds would
    // otherwise log the set twice, which is easy to do with a phone on a bench.
    if (_saving) return;
    setState(() {
      _error = null;
      _saving = true;
    });

    try {
      await ref.read(loggingRepositoryProvider).logSet(
            sessionExerciseId: widget.sessionExerciseId,
            exerciseId: widget.exerciseId,
            weightKg: weight,
            reps: reps,
            rir: rir,
          );

      // Rest starts the moment the set is logged, which is the moment it
      // actually started. Read the template fresh rather than caching it, so an
      // edit made mid-session takes effect on the next set.
      final prescription = await ref
          .read(progressionRepositoryProvider)
          .prescriptionFor(widget.exerciseId);
      if (!mounted) return;
      ref.read(restTimerProvider.notifier).start(
            Duration(seconds: prescription.restSeconds ?? defaultRest.inSeconds),
            exerciseId: widget.exerciseId,
          );
    } finally {
      // The values stay put: the next set is usually this set again, and
      // clearing them was the single biggest reason logging felt like data
      // entry rather than training.
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              flex: 5,
              child: _Stepper(
                controller: _weight,
                label: 'kg',
                decimal: true,
                onDown: () => _nudgeWeight(-_loadStep),
                onUp: () => _nudgeWeight(_loadStep),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 4,
              child: _Stepper(
                controller: _reps,
                label: 'reps',
                onDown: () => _nudgeReps(-1),
                onUp: () => _nudgeReps(1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 84,
              child: _Field(
                controller: _rir,
                label: 'RIR',
                hint: '—',
                decimal: true,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: _saving ? null : _log,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: Text(_saving ? 'Logging…' : 'Log set'),
              ),
            ),
          ],
        ),
        if (_error case final message?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

/// A number with a minus on one side and a plus on the other.
///
/// The buttons are the point: between sets, with chalk on your hands and a
/// minute of rest, tapping plus twice is a different act from opening a
/// keyboard and retyping 62.5. The field is still there for the times the jump
/// is not a multiple of anything.
class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.controller,
    required this.label,
    required this.onDown,
    required this.onUp,
    this.decimal = false,
  });

  final TextEditingController controller;
  final String label;
  final VoidCallback onDown;
  final VoidCallback onUp;
  final bool decimal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Above the box, not inside it. Flutter hides `suffixText` until the
        // field has focus or content, so an empty weight box and an empty reps
        // box are the same blank rectangle — which is exactly what they looked
        // like the first time this was built.
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 1,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              _NudgeButton(
                icon: Icons.remove,
                onPressed: onDown,
                label: '$label down',
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  keyboardType:
                      TextInputType.numberWithOptions(decimal: decimal),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      decimal ? RegExp(r'[0-9.,]') : RegExp(r'[0-9]'),
                    ),
                  ],
                  textAlign: TextAlign.center,
                  textInputAction: TextInputAction.done,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  // Tapping the number selects all of it, so typing replaces
                  // rather than appending to what is already there — otherwise
                  // editing 100 into 105 produces 100105 more often than not.
                  onTap: () => controller.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: controller.text.length,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: '—',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                  ),
                ),
              ),
              _NudgeButton(
                icon: Icons.add,
                onPressed: onUp,
                label: '$label up',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({
    required this.icon,
    required this.onPressed,
    required this.label,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      tooltip: label,
      // A comfortable target for a thumb, which is what is available.
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.hint,
    this.decimal = false,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool decimal;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
          decimal ? RegExp(r'[0-9.,]') : RegExp(r'[0-9]'),
        ),
      ],
      textAlign: TextAlign.center,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        hintText: hint,
        labelText: label,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      ),
    );
  }
}

/// Sets done against sets planned. Turns green once the plan is met, so the
/// answer to "am I finished with this one?" is available at a glance, from
/// arm's length, between sets.
class _SetCount extends StatelessWidget {
  const _SetCount({required this.done, required this.planned});

  final int done;
  final int planned;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final met = done >= planned;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        '$done/$planned',
        style: theme.textTheme.labelLarge?.copyWith(
          color: met
              ? PillarColors.of(context).fuel
              : theme.colorScheme.onSurfaceVariant,
          fontWeight: met ? FontWeight.w700 : FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// What to put on the bar for the engine's target.
///
/// Shown next to the target rather than behind a tap: the lifter is standing
/// at the rack working it out in their head otherwise, and the arithmetic is
/// the same every time.
class _Plates extends StatelessWidget {
  const _Plates({required this.targetKg});

  final double targetKg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final load = platesFor(targetKg: targetKg);
    if (load.belowBar || load.perSide.isEmpty) return const SizedBox.shrink();

    final plates = load.perSide.map(formatPlate).join(' + ');
    return Text(
      load.isExact
          ? 'Bar + $plates per side'
          // Never claim a weight the plates cannot make.
          : 'Bar + $plates per side — ${formatWeight(load.totalKg)}, '
              'closest below',
      style: theme.textTheme.labelMedium
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

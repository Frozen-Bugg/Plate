import 'package:engine/engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/db/app_database.dart';
import '../../core/format.dart';
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
    final library = ref.watch(exerciseLibraryProvider).value ?? const [];
    final name = library
        .where((e) => e.id == exerciseId)
        .map((e) => e.name)
        .firstOrNull;
    return Text(
      name ?? 'Exercise',
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

/// Weight, reps and optional RIR, then Log. Prefilled from the engine's target
/// on the first set and from the previous set after that, because the common
/// case is repeating what you just did.
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

  @override
  void dispose() {
    _weight.dispose();
    _reps.dispose();
    _rir.dispose();
    super.dispose();
  }

  String? get _weightHint {
    final source = widget.lastSet?.weightKg ?? widget.suggestedLoad;
    return source == null ? 'kg' : formatWeight(source);
  }

  String? get _repsHint {
    final source = widget.lastSet?.reps ?? widget.suggestedReps;
    return source?.toString() ?? 'reps';
  }

  Future<void> _log() async {
    // An empty field means "same as the hint", which is what the lifter sees.
    final weight = double.tryParse(_weight.text.trim()) ??
        widget.lastSet?.weightKg ??
        widget.suggestedLoad;
    final reps = int.tryParse(_reps.text.trim()) ??
        widget.lastSet?.reps ??
        widget.suggestedReps;
    final rir = _rir.text.trim().isEmpty ? null : double.tryParse(_rir.text.trim());

    if (weight == null || reps == null || reps < 1) {
      setState(() => _error = 'Enter a weight and at least one rep');
      return;
    }
    setState(() => _error = null);

    await ref.read(loggingRepositoryProvider).logSet(
          sessionExerciseId: widget.sessionExerciseId,
          exerciseId: widget.exerciseId,
          weightKg: weight,
          reps: reps,
          rir: rir,
        );
    _weight.clear();
    _reps.clear();
    _rir.clear();

    // Rest starts the moment the set is logged, which is the moment it
    // actually started. Read the template fresh rather than caching it, so an
    // edit made mid-session takes effect on the next set.
    final prescription = await ref
        .read(progressionRepositoryProvider)
        .prescriptionFor(widget.exerciseId);
    ref.read(restTimerProvider.notifier).start(
          Duration(seconds: prescription.restSeconds ?? defaultRest.inSeconds),
          exerciseId: widget.exerciseId,
        );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: _Field(
                controller: _weight,
                hint: _weightHint,
                label: 'kg',
                decimal: true,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 2,
              child:
                  _Field(controller: _reps, hint: _repsHint, label: 'reps'),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 2,
              child: _Field(
                controller: _rir,
                hint: 'RIR',
                label: 'RIR',
                decimal: true,
              ),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: _log,
              style: FilledButton.styleFrom(
                minimumSize: const Size(64, 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('Log'),
            ),
          ],
        ),
        if (_error case final message?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
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
          decimal ? RegExp(r'[0-9.]') : RegExp(r'[0-9]'),
        ),
      ],
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        hintText: hint,
        labelText: label,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      ),
    );
  }
}

/// Opens the exercise picker and returns what was chosen, or null if the sheet
/// was dismissed. Shared by the live session and the template editor.
Future<Exercise?> showExercisePicker(BuildContext context) =>
    showModalBottomSheet<Exercise>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ExercisePicker(),
    );

/// The seeded library plus anything the lifter added, filtered by name.
class _ExercisePicker extends ConsumerStatefulWidget {
  const _ExercisePicker();

  @override
  ConsumerState<_ExercisePicker> createState() => _ExercisePickerState();
}

class _ExercisePickerState extends ConsumerState<_ExercisePicker> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(exerciseLibraryProvider).value ?? const [];
    final needle = _query.text.trim().toLowerCase();
    final shown = needle.isEmpty
        ? all
        : all.where((e) => e.name.toLowerCase().contains(needle)).toList();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Search exercises',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: shown.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Text('No exercise matches that.'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: shown.length,
                      itemBuilder: (context, i) => ListTile(
                        title: Text(shown[i].name),
                        subtitle: Text(shown[i].equipment),
                        onTap: () => Navigator.pop(context, shown[i]),
                      ),
                    ),
            ),
          ],
        ),
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

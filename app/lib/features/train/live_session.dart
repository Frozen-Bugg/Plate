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
import 'voice_sets_sheet.dart';

/// The exercises in the running session, each with its logged sets and a row
/// for adding the next one.
///
/// Reordered by dragging a handle, same shape as the template editor's list —
/// local order between rebuilds so a drag never snaps back while its write is
/// still in flight, reconciled against the stream only when an exercise is
/// actually added or removed.
class LiveSessionExercises extends ConsumerStatefulWidget {
  const LiveSessionExercises({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<LiveSessionExercises> createState() =>
      _LiveSessionExercisesState();
}

class _LiveSessionExercisesState extends ConsumerState<LiveSessionExercises> {
  List<SessionExercise> _order = const [];
  String? _syncedFor;

  Future<void> _pickExercise() async {
    final chosen = await showExercisePicker(context);
    if (chosen == null) return;
    await ref
        .read(loggingRepositoryProvider)
        .addExercise(sessionId: widget.sessionId, exerciseId: chosen.id);
  }

  void _reorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = _order.removeAt(oldIndex);
    setState(() => _order = [..._order..insert(newIndex, moved)]);
    ref.read(loggingRepositoryProvider).reorderExercises(
          widget.sessionId,
          [for (final e in _order) e.id],
        );
  }

  @override
  Widget build(BuildContext context) {
    final exercises =
        ref.watch(sessionExercisesProvider(widget.sessionId)).value ??
            const [];

    final incoming = {for (final e in exercises) e.id};
    final shown = {for (final e in _order) e.id};
    if (_syncedFor != widget.sessionId ||
        incoming.length != shown.length ||
        !incoming.containsAll(shown)) {
      _order = exercises;
      _syncedFor = widget.sessionId;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_order.isNotEmpty)
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: _order.length,
            onReorder: _reorder,
            // A handle is already built into each block's header; the
            // automatic one would double up on top of it.
            buildDefaultDragHandles: false,
            itemBuilder: (context, i) => Padding(
              key: ValueKey(_order[i].id),
              padding: const EdgeInsets.only(bottom: 12),
              child: _ExerciseBlock(sessionExercise: _order[i], dragIndex: i),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickExercise,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('Add exercise'),
              ),
            ),
            const SizedBox(width: 8),
            // For the sets already done before the phone came out — "three by
            // eight at eighty on bench" is faster than four taps per set.
            IconButton.filledTonal(
              tooltip: 'Say your sets',
              onPressed: () =>
                  showVoiceSetsSheet(context, sessionId: widget.sessionId),
              icon: const Icon(Icons.mic_none),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          ],
        ),
      ],
    );
  }
}

/// One exercise: what the engine wants this time, what has been logged, and
/// a Hevy-style table — one row per set, done or still to come — for logging
/// the rest.
class _ExerciseBlock extends ConsumerWidget {
  const _ExerciseBlock({required this.sessionExercise, required this.dragIndex});

  final SessionExercise sessionExercise;

  /// This block's position in the enclosing `ReorderableListView` — the
  /// header's drag handle needs it.
  final int dragIndex;

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
    final previous = ref
            .watch(previousSetsProvider((
              exerciseId: sessionExercise.exerciseId,
              sessionId: sessionExercise.sessionId,
            )))
            .value ??
        const <WorkoutSet>[];

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
              // A handle rather than the whole row, matching the template
              // editor — a scroll must never register as a drag.
              ReorderableDragStartListener(
                index: dragIndex,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
                ),
              ),
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
          const _TableHeader(),
          for (final set in sets)
            _DoneSetRow(
              set: set,
              previous: set.setIndex < previous.length
                  ? previous[set.setIndex]
                  : null,
              onDelete: () =>
                  ref.read(loggingRepositoryProvider).deleteSet(set.id),
            ),
          _AddSetRow(
            sessionExerciseId: sessionExercise.id,
            exerciseId: sessionExercise.exerciseId,
            setIndex: sets.length,
            previous: sets.length < previous.length
                ? previous[sets.length]
                : null,
            suggestedLoad: target?.nextLoadKg,
            suggestedReps: target?.nextReps,
            lastSet: sets.isEmpty ? null : sets.last,
          ),
          // Sets the plan calls for but has not reached yet — Hevy lays the
          // whole set out before you touch it, so "three sets" reads as three
          // rows, not a promise the app is keeping to itself.
          if (planned != null)
            for (var i = sets.length + 1; i < planned; i++)
              _UpcomingSetRow(
                setIndex: i,
                previous: i < previous.length ? previous[i] : null,
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

/// Column labels for the set table. SET and PREVIOUS bracket the input
/// columns on the left the way Hevy's does, so the eye has somewhere to land
/// before the numbers start moving.
class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          letterSpacing: 0.5,
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: 26, child: Text('SET', style: style)),
          SizedBox(width: 64, child: Text('PREVIOUS', style: style)),
          const Expanded(child: SizedBox.shrink()),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

/// What [set] was logged at, laid against the same set index last time it was
/// trained. "80 x 8" on its own answers "what did I lift"; next to "77.5 x 8"
/// it answers the question that is actually being asked mid-workout, which is
/// whether this is progress.
class _DoneSetRow extends StatelessWidget {
  const _DoneSetRow({
    required this.set,
    required this.previous,
    required this.onDelete,
  });

  final WorkoutSet set;
  final WorkoutSet? previous;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final weight = set.weightKg;
    final reps = set.reps;

    return Dismissible(
      key: ValueKey(set.id),
      direction: DismissDirection.endToStart,
      background: ColoredBox(
        color: theme.colorScheme.error,
        child: const Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.only(right: 16),
            child: Icon(Icons.delete_outline, color: Colors.white, size: 18),
          ),
        ),
      ),
      onDismissed: (_) => onDelete(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${set.setIndex + 1}',
                style: theme.textTheme.labelLarge?.copyWith(color: muted),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                _previousText(previous),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      weight == null || reps == null
                          ? '—'
                          : '${formatWeight(weight)} x $reps'
                              '${set.rir == null ? '' : '  @${formatRir(set.rir!)}'}',
                      style: theme.textTheme.bodyLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (set.isPr)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.emoji_events,
                        size: 16,
                        color: PillarColors.of(context).move,
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: 40,
              child: Icon(
                Icons.check_circle,
                color: PillarColors.of(context).fuel,
                size: 22,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A set the plan calls for but has not been reached yet: a placeholder row,
/// numbered and given its own "previous" for reference, with nothing to tap.
/// It exists to be seen, not touched — logging happens in order, one row at a
/// time, because `logSet` numbers a set by how many already exist.
class _UpcomingSetRow extends StatelessWidget {
  const _UpcomingSetRow({required this.setIndex, required this.previous});

  final int setIndex;
  final WorkoutSet? previous;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '${setIndex + 1}',
              style: theme.textTheme.labelLarge?.copyWith(color: faint),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              _previousText(previous),
              style: theme.textTheme.bodySmall?.copyWith(color: faint),
            ),
          ),
          Expanded(
            child: Text('—', style: theme.textTheme.bodyLarge?.copyWith(color: faint)),
          ),
          SizedBox(
            width: 40,
            child: Icon(Icons.radio_button_unchecked, color: faint, size: 20),
          ),
        ],
      ),
    );
  }
}

String _previousText(WorkoutSet? set) {
  if (set == null) return '—';
  final weight = set.weightKg;
  final reps = set.reps;
  if (weight == null || reps == null) return '—';
  return '${formatWeight(weight)} x $reps';
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
    required this.setIndex,
    required this.previous,
    this.suggestedLoad,
    this.suggestedReps,
    this.lastSet,
  });

  final String sessionExerciseId;
  final String exerciseId;

  /// This row's position in the exercise — 0 for the first set. Shown as
  /// `setIndex + 1`, and lines it up with [previous]'s own row.
  final int setIndex;

  /// What was logged at this same set index last time, for the PREVIOUS
  /// column. Null past the end of last time's sets, or with no history at all.
  final WorkoutSet? previous;
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
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Same three leading columns as every other row in the table — SET,
          // PREVIOUS, then the part that is actually this row's own: here, the
          // inputs instead of a plain number.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: SizedBox(
                  width: 26,
                  child: Text(
                    '${widget.setIndex + 1}',
                    style: theme.textTheme.labelLarge?.copyWith(color: muted),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 14, right: 4),
                child: SizedBox(
                  width: 60,
                  child: Text(
                    _previousText(widget.previous),
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _Stepper(
                        controller: _weight,
                        label: 'kg',
                        decimal: true,
                        onDown: () => _nudgeWeight(-_loadStep),
                        onUp: () => _nudgeWeight(_loadStep),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _Stepper(
                        controller: _reps,
                        label: 'reps',
                        onDown: () => _nudgeReps(-1),
                        onUp: () => _nudgeReps(1),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 14),
                child: _CheckButton(
                  saving: _saving,
                  onPressed: _saving ? null : _log,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 90, top: 8),
            child: SizedBox(
              width: 84,
              child: _Field(
                controller: _rir,
                label: 'RIR',
                hint: '—',
                decimal: true,
              ),
            ),
          ),
          if (_error case final message?)
            Padding(
              padding: const EdgeInsets.only(left: 90, top: 6),
              child: Text(
                message,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// The checkmark that commits the row it sits in — Hevy's gesture for "this
/// set is done" and the reason this table needs no separate Log button.
class _CheckButton extends StatelessWidget {
  const _CheckButton({required this.saving, required this.onPressed});

  final bool saving;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 40,
      height: 40,
      child: Material(
        color: scheme.primaryContainer,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Center(
            child: saving
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onPrimaryContainer,
                    ),
                  )
                : Icon(Icons.check, color: scheme.onPrimaryContainer, size: 22),
          ),
        ),
      ),
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/format.dart';
import 'exercises_repository.dart';

/// Opens the exercise picker and returns what was chosen, or null if the sheet
/// was dismissed. Shared by the live session and the template editor.
Future<Exercise?> showExercisePicker(BuildContext context) =>
    showModalBottomSheet<Exercise>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ExercisePicker(),
    );

/// The seeded library plus anything the lifter added, filtered by name — and a
/// way to add the one that is missing.
///
/// Every gym has a machine nobody else's gym has. Before this, searching for it
/// ended at "No exercise matches that", which is a dead end in the middle of a
/// workout: the choice was to log it under the wrong name or not log it at all.
class _ExercisePicker extends ConsumerStatefulWidget {
  const _ExercisePicker();

  @override
  ConsumerState<_ExercisePicker> createState() => _ExercisePickerState();
}

class _ExercisePickerState extends ConsumerState<_ExercisePicker> {
  final _query = TextEditingController();
  var _needle = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _create(String name) async {
    final details = await showModalBottomSheet<_NewExercise>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: _NewExerciseSheet(initialName: name),
      ),
    );
    if (details == null || !mounted) return;

    final exercise = await ref.read(exercisesRepositoryProvider).create(
          name: details.name,
          equipment: details.equipment,
          loadStepKg: details.loadStepKg,
          unilateral: details.unilateral,
        );
    if (mounted) Navigator.pop(context, exercise);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final all = ref.watch(exerciseLibraryProvider).value ?? const <Exercise>[];
    final needle = _needle.trim().toLowerCase();
    final shown = needle.isEmpty
        ? all
        : all.where((e) => e.name.toLowerCase().contains(needle)).toList();

    // Only offer to create when the name is not already taken exactly. A
    // partial match still offers it — "Row" matching "Barbell Row" does not
    // mean the lifter meant that one.
    final exact = all.any((e) => e.name.toLowerCase() == needle);
    final canCreate = needle.isNotEmpty && !exact;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onChanged: (value) => setState(() => _needle = value),
              decoration: const InputDecoration(
                hintText: 'Search or add an exercise',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (canCreate)
                    ListTile(
                      leading: const Icon(Icons.add),
                      title: Text('Add "${_query.text.trim()}"'),
                      subtitle: Text(
                        'Your own movement, on every device',
                        style: text.labelSmall?.copyWith(color: muted),
                      ),
                      onTap: () => _create(_query.text.trim()),
                    ),
                  if (shown.isEmpty && !canCreate)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          'No exercise matches that.',
                          style: text.bodyMedium?.copyWith(color: muted),
                        ),
                      ),
                    ),
                  for (final exercise in shown)
                    ListTile(
                      title: Text(exercise.name),
                      subtitle: Text(
                        [
                          exercise.equipment,
                          if (exercise.unilateral) 'per side',
                          '+${formatPlate(exercise.loadStepKg)} kg steps',
                        ].join(' · '),
                        style: text.labelSmall?.copyWith(color: muted),
                      ),
                      // Only what the lifter made is theirs to change; the
                      // seeded library is shared and read-only.
                      trailing: exercise.userId == null
                          ? null
                          : IconButton(
                              tooltip: 'Edit',
                              icon: const Icon(Icons.tune, size: 18),
                              onPressed: () => _edit(exercise),
                            ),
                      onTap: () => Navigator.pop(context, exercise),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(Exercise exercise) async {
    final details = await showModalBottomSheet<_NewExercise>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: _NewExerciseSheet(
          initialName: exercise.name,
          initialEquipment: exercise.equipment,
          initialLoadStep: exercise.loadStepKg,
          initialUnilateral: exercise.unilateral,
          existing: exercise,
        ),
      ),
    );
    if (details == null || !mounted) return;

    if (details.delete) {
      await ref.read(exercisesRepositoryProvider).delete(exercise.id);
      return;
    }
    await ref.read(exercisesRepositoryProvider).update(
          exercise.id,
          name: details.name,
          equipment: details.equipment,
          loadStepKg: details.loadStepKg,
          unilateral: details.unilateral,
        );
  }
}

/// What the new-exercise sheet hands back.
class _NewExercise {
  const _NewExercise({
    required this.name,
    required this.equipment,
    required this.loadStepKg,
    required this.unilateral,
    this.delete = false,
  });

  final String name;
  final String equipment;
  final double loadStepKg;
  final bool unilateral;
  final bool delete;
}

/// Name, equipment and load step — the three things the engine needs.
///
/// Muscles and movement pattern are left out deliberately. They are used for
/// balance reporting later, and asking for them here would put four more
/// decisions between a lifter and the set they are standing there waiting to
/// log.
class _NewExerciseSheet extends StatefulWidget {
  const _NewExerciseSheet({
    required this.initialName,
    this.initialEquipment = 'barbell',
    this.initialLoadStep,
    this.initialUnilateral = false,
    this.existing,
  });

  final String initialName;
  final String initialEquipment;
  final double? initialLoadStep;
  final bool initialUnilateral;
  final Exercise? existing;

  @override
  State<_NewExerciseSheet> createState() => _NewExerciseSheetState();
}

class _NewExerciseSheetState extends State<_NewExerciseSheet> {
  late final _name = TextEditingController(text: widget.initialName);
  late String _equipment = widget.initialEquipment;
  late double _step = widget.initialLoadStep ?? defaultLoadStep(_equipment);
  late bool _unilateral = widget.initialUnilateral;

  /// Whether the step was chosen by hand. Until it is, changing the equipment
  /// moves it to that equipment's usual jump — which is right nearly always,
  /// and never right after the lifter has overridden it.
  var _stepTouched = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final editing = widget.existing != null;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(editing ? 'Edit exercise' : 'New exercise',
                style: text.headlineSmall),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: !editing,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),
            Text('EQUIPMENT',
                style:
                    text.labelSmall?.copyWith(color: muted, letterSpacing: 1)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final kind in equipmentKinds)
                  ChoiceChip(
                    label: Text(kind),
                    selected: _equipment == kind,
                    onSelected: (_) => setState(() {
                      _equipment = kind;
                      if (!_stepTouched) _step = defaultLoadStep(kind);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Smallest jump', style: text.bodyMedium),
                      Text(
                        'What the engine adds when you clear a target',
                        style: text.labelSmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                _StepPicker(
                  value: _step,
                  onChanged: (value) => setState(() {
                    _step = value;
                    _stepTouched = true;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _unilateral,
              title: const Text('One side at a time'),
              subtitle: Text(
                'Logged per side, like a split squat',
                style: text.labelSmall?.copyWith(color: muted),
              ),
              onChanged: (value) => setState(() => _unilateral = value),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _valid ? _save : null,
              child: Text(editing ? 'Save' : 'Add it'),
            ),
            if (editing) ...[
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: _confirmDelete,
                  child: const Text('Remove from my list'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _save() {
    if (!_valid) return;
    Navigator.pop(
      context,
      _NewExercise(
        name: _name.text.trim(),
        equipment: _equipment,
        loadStepKg: _step,
        unilateral: _unilateral,
      ),
    );
  }

  /// Removing is a soft delete that syncs to every device, so it is worth one
  /// confirmation. The sets already logged against it stay: they are history.
  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${_name.text.trim()}?'),
        content: const Text(
          'It leaves the picker on every device. Workouts you have already '
          'logged with it are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.pop(
      context,
      _NewExercise(
        name: _name.text.trim(),
        equipment: _equipment,
        loadStepKg: _step,
        unilateral: _unilateral,
        delete: true,
      ),
    );
  }
}

/// The load step, offered as the jumps that actually exist in a gym.
class _StepPicker extends StatelessWidget {
  const _StepPicker({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  static const _steps = [1.0, 1.25, 2.0, 2.5, 5.0];

  @override
  Widget build(BuildContext context) {
    // A value from an older row might not be one of the offered jumps; showing
    // it keeps the menu honest rather than silently moving it.
    final options = {..._steps, value}.toList()..sort();
    return DropdownButton<double>(
      value: value,
      underline: const SizedBox.shrink(),
      items: [
        for (final step in options)
          DropdownMenuItem(
            value: step,
            child: Text('${formatPlate(step)} kg'),
          ),
      ],
      onChanged: (chosen) => chosen == null ? null : onChanged(chosen),
    );
  }
}

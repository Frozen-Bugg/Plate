import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import 'exercise_picker.dart';
import 'exercises_repository.dart';
import 'sessions_repository.dart';
import 'templates_repository.dart';

/// The saved plans. A template is what you intend to do; starting one copies
/// its exercises into a new session.
class TemplatesScreen extends ConsumerWidget {
  const TemplatesScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await promptForText(
      context,
      title: 'New template',
      hint: 'Push A, Legs, Upper…',
    );
    if (name == null || name.isEmpty) return;
    final id = await ref.read(templatesRepositoryProvider).create(name: name);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TemplateEditorScreen(templateId: id),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(templatesProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Templates')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
      body: switch (templates) {
        AsyncData(:final value) when value.isEmpty => Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'A template is a workout you repeat. Build one, and the engine '
              'uses its rep range and target effort to set your next load.',
              style: text.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        AsyncData(:final value) => ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: value.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _TemplateTile(template: value[i]),
          ),
        AsyncError(:final error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text("Couldn't load your templates.\n$error"),
            ),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _TemplateTile extends ConsumerWidget {
  const _TemplateTile({required this.template});

  final Template template;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exercises =
        ref.watch(templateExercisesProvider(template.id)).value ?? const [];
    return ListTile(
      title: Text(template.name),
      subtitle: Text(
        exercises.isEmpty
            ? 'No exercises yet'
            : '${exercises.length} exercise${exercises.length == 1 ? '' : 's'}',
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TemplateEditorScreen(templateId: template.id),
        ),
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (action) async {
          switch (action) {
            case 'rename':
              final name = await promptForText(
                context,
                title: 'Rename template',
                initial: template.name,
              );
              if (name != null && name.isNotEmpty) {
                await ref
                    .read(templatesRepositoryProvider)
                    .rename(template.id, name);
              }
            case 'delete':
              if (!context.mounted) return;
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Delete ${template.name}?'),
                  content: const Text('It will be removed from every device.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Keep'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await ref
                    .read(templatesRepositoryProvider)
                    .delete(template.id);
              }
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

/// Exercises in a template, each with the prescription the engine reads.
class TemplateEditorScreen extends ConsumerWidget {
  const TemplateEditorScreen({super.key, required this.templateId});

  final String templateId;

  Future<void> _addExercise(BuildContext context, WidgetRef ref) async {
    final chosen = await showExercisePicker(context);
    if (chosen == null) return;
    await ref
        .read(templatesRepositoryProvider)
        .addExercise(templateId: templateId, exerciseId: chosen.id);
  }

  /// Starts the template, then leaves the templates stack entirely — the
  /// running workout is on the Train tab, and popping back to a list of
  /// templates makes it look as though nothing happened.
  Future<void> _start(BuildContext context, WidgetRef ref) async {
    // Two open sessions would orphan the earlier one, so offer the running
    // workout instead of quietly starting a second.
    if (ref.read(activeSessionProvider) != null) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('A workout is already running'),
          content: const Text(
            'Finish or discard it before starting another.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Stay here'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Go to it'),
            ),
          ],
        ),
      );
      if (go == true && context.mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      return;
    }

    await ref.read(templatesRepositoryProvider).startSession(templateId);
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planned = ref.watch(templateExercisesProvider(templateId));
    final template = ref
        .watch(templatesProvider)
        .value
        ?.where((t) => t.id == templateId)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(template?.name ?? 'Template')),
      body: Column(
        children: [
          Expanded(
            child: _ReorderableExercises(
              templateId: templateId,
              planned: planned.value ?? const [],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _addExercise(context, ref),
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('Add exercise'),
                ),
                const SizedBox(height: 12),
                if ((planned.value ?? const []).isNotEmpty)
                  FilledButton.icon(
                    onPressed: () => _start(context, ref),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Start this workout'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Exercises in a template, reordered by dragging a handle.
///
/// Held in local state between rebuilds rather than read straight off the
/// stream every time: a drag has to feel instant, but the write it triggers is
/// still a round trip through the database, and rendering the stream's answer
/// mid-drag would snap the row back to its old spot for the half-second before
/// the write lands. Local state is the order shown; the stream is only
/// consulted to notice an exercise added or removed elsewhere.
class _ReorderableExercises extends ConsumerStatefulWidget {
  const _ReorderableExercises({
    required this.templateId,
    required this.planned,
  });

  final String templateId;
  final List<TemplateExercise> planned;

  @override
  ConsumerState<_ReorderableExercises> createState() =>
      _ReorderableExercisesState();
}

class _ReorderableExercisesState extends ConsumerState<_ReorderableExercises> {
  late List<TemplateExercise> _order = widget.planned;

  @override
  void didUpdateWidget(_ReorderableExercises old) {
    super.didUpdateWidget(old);
    final incoming = {for (final e in widget.planned) e.id};
    final shown = {for (final e in _order) e.id};
    // Same set of exercises, in whatever order the last drag left them: the
    // stream has caught up, and there is nothing to reconcile. Only a real
    // add or remove replaces the local order outright.
    if (incoming.length == shown.length && incoming.containsAll(shown)) {
      return;
    }
    _order = widget.planned;
  }

  void _reorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = _order.removeAt(oldIndex);
    setState(() => _order = [..._order..insert(newIndex, moved)]);
    ref
        .read(templatesRepositoryProvider)
        .reorderExercises(widget.templateId, [for (final e in _order) e.id]);
  }

  @override
  Widget build(BuildContext context) {
    if (_order.isEmpty) {
      final text = Theme.of(context).textTheme;
      final muted = Theme.of(context).colorScheme.onSurfaceVariant;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Add the first exercise below.',
            style: text.bodyMedium?.copyWith(color: muted),
          ),
        ),
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: _order.length,
      onReorder: _reorder,
      // A handle is already built into each row below; the automatic one
      // would double up on top of it.
      buildDefaultDragHandles: false,
      itemBuilder: (context, i) => Padding(
        key: ValueKey(_order[i].id),
        padding: const EdgeInsets.only(bottom: 12),
        child: _PlannedExercise(planned: _order[i], dragIndex: i),
      ),
    );
  }
}

/// One exercise's prescription: sets, rep range and target effort. These are
/// what the engine judges a session against, so they are editable here and
/// nowhere else.
class _PlannedExercise extends ConsumerWidget {
  const _PlannedExercise({required this.planned, required this.dragIndex});

  final TemplateExercise planned;

  /// This row's position in the enclosing `ReorderableListView` — the handle
  /// needs it, and the row itself has no other way to know.
  final int dragIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final library = ref.watch(exerciseLibraryProvider).value ?? const [];
    final name = library
        .where((e) => e.id == planned.exerciseId)
        .map((e) => e.name)
        .firstOrNull;
    final repo = ref.read(templatesRepositoryProvider);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // A handle rather than the whole row, so the number fields below
              // stay tappable and a scroll never gets mistaken for a drag.
              ReorderableDragStartListener(
                index: dragIndex,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    Icons.drag_handle,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  name ?? 'Exercise',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => repo.removeExercise(planned.id),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  label: 'sets',
                  value: planned.sets,
                  onChanged: (v) =>
                      repo.updatePrescription(planned.id, sets: v),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _NumberField(
                  label: 'rep min',
                  value: planned.repMin,
                  onChanged: (v) =>
                      repo.updatePrescription(planned.id, repMin: v),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _NumberField(
                  label: 'rep max',
                  value: planned.repMax,
                  onChanged: (v) =>
                      repo.updatePrescription(planned.id, repMax: v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Two rows rather than five across: at five, "rep min" and "rep max"
          // both truncate to "rep …" and the field stops saying what it is.
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  label: 'target RIR',
                  value: planned.targetRir?.round(),
                  onChanged: (v) => repo.updatePrescription(
                    planned.id,
                    targetRir: Value(v?.toDouble()),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _NumberField(
                  // Blank means the app's default rest applies.
                  label: 'rest (s)',
                  value: planned.restSeconds,
                  onChanged: (v) => repo.updatePrescription(
                    planned.id,
                    restSeconds: Value(v),
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Commits on blur or submit rather than on every keystroke, so a half-typed
/// "1" on the way to "12" never reaches the database.
class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int? value;
  final void Function(int?) onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value?.toString() ?? '');
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChange);

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final text = _controller.text.trim();
    final parsed = text.isEmpty ? null : int.tryParse(text);
    if (parsed != widget.value) widget.onChanged(parsed);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _commit(),
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      ),
    );
  }
}

/// A single-field dialog, used for naming and renaming templates.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  String? initial,
  String? hint,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

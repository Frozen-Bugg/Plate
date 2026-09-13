import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'groceries_repository.dart';
import 'week_plan_sheet.dart';

/// The shopping list.
///
/// Read one-handed in a shop, which is why the lines are big, the tick is the
/// whole row, and what is already in the basket sinks to the bottom rather than
/// disappearing — a list that rearranges itself under your thumb is one you
/// lose your place in.
class GroceriesScreen extends ConsumerWidget {
  const GroceriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final lists = ref.watch(groceryListsProvider).value;
    final list = ref.watch(currentGroceryListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shopping'),
        actions: [
          if (list != null)
            PopupMenuButton<String>(
              onSelected: (choice) async {
                if (choice == 'delete') {
                  await ref
                      .read(groceriesRepositoryProvider)
                      .deleteList(list.id);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'delete', child: Text('Throw the list away')),
              ],
            ),
        ],
      ),
      floatingActionButton: list == null
          ? FloatingActionButton.extended(
              onPressed: () => showWeekPlanSheet(context),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Plan the week'),
            )
          : FloatingActionButton.small(
              tooltip: 'Add something',
              onPressed: () => _add(context, ref, list.id),
              child: const Icon(Icons.add),
            ),
      body: switch ((lists, list)) {
        (null, _) => const Center(child: CircularProgressIndicator()),
        (_, null) => _Empty(muted: muted, text: text),
        (_, final current?) => _Lines(list: current),
      },
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref, String listId) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add to the list'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Bin bags'),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await ref.read(groceriesRepositoryProvider).add(listId: listId, name: name);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.muted, required this.text});

  final Color muted;
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shopping_basket_outlined, size: 40, color: muted),
            const SizedBox(height: 12),
            Text('No list yet', style: text.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Plan a week of cooking and the shopping falls out of it — '
              'every ingredient, summed by food, in units a shop uses.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _Lines extends ConsumerWidget {
  const _Lines({required this.list});

  final GroceryList list;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    // Ticked lines sink, in their original order, rather than vanishing. You
    // look back at what you have already picked up more often than you expect.
    final outstanding = [for (final l in list.lines) if (!l.checked) l];
    final done = [for (final l in list.lines) if (l.checked) l];

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Text(
            list.isDone
                ? 'Everything on the list'
                : '${list.left} left of ${list.lines.length}',
            style: text.labelLarge?.copyWith(color: muted),
          ),
        ),
        for (final line in outstanding) _Line(line: line),
        if (done.isNotEmpty) ...[
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text(
              'IN THE BASKET',
              style: text.labelSmall?.copyWith(color: muted, letterSpacing: 1),
            ),
          ),
          for (final line in done) _Line(line: line),
        ],
      ],
    );
  }
}

class _Line extends ConsumerWidget {
  const _Line({required this.line});

  final GroceryLine line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Dismissible(
      key: ValueKey(line.id),
      direction: DismissDirection.endToStart,
      background: ColoredBox(
        color: theme.colorScheme.error,
        child: const Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.only(right: 20),
            child: Icon(Icons.delete_outline, color: Colors.white),
          ),
        ),
      ),
      onDismissed: (_) =>
          ref.read(groceriesRepositoryProvider).removeLine(line.id),
      child: CheckboxListTile(
        value: line.checked,
        // The whole row, because this is done one-handed with a trolley in the
        // other one.
        onChanged: (value) => ref
            .read(groceriesRepositoryProvider)
            .setChecked(line.id, checked: value ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          line.name,
          style: line.checked
              ? text.bodyLarge?.copyWith(
                  color: muted,
                  decoration: TextDecoration.lineThrough,
                )
              : text.bodyLarge,
        ),
        secondary: line.amount.isEmpty
            ? null
            : Text(line.amount, style: text.labelLarge?.copyWith(color: muted)),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../app/widgets/tab_scaffold.dart';
import '../../core/db/app_database.dart';
import '../../core/format.dart';
import 'live_session.dart';
import 'logging_repository.dart';
import 'progression_repository.dart';
import 'sessions_repository.dart';
import 'templates_screen.dart';

class TrainScreen extends ConsumerWidget {
  const TrainScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(recentSessionsProvider);
    final active = ref.watch(activeSessionProvider);
    final text = Theme.of(context).textTheme;

    return TabScaffold(
      title: 'Train',
      body: switch (sessions) {
        AsyncData(:final value) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (active != null)
                ActiveSessionCard(session: active)
              else
                FilledButton.icon(
                  onPressed: () =>
                      ref.read(sessionsRepositoryProvider).start(),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Start workout'),
                ),
              const SizedBox(height: 8),
              // Reachable mid-workout too: checking the plan is exactly what
              // you want to do while resting between sets.
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TemplatesScreen(),
                  ),
                ),
                icon: const Icon(Icons.list_alt, size: 20),
                label: const Text('Templates'),
              ),
              const SizedBox(height: 28),
              Text('History', style: text.titleLarge),
              const SizedBox(height: 8),
              if (value.every((s) => s.endedAt == null))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Finished workouts show up here, even when you log them offline.',
                    style: text.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Card(
                  child: Column(
                    children: [
                      for (final (i, session) in value
                          .where((s) => s.endedAt != null)
                          .indexed) ...[
                        if (i > 0) const Divider(indent: 16, endIndent: 16),
                        _SessionTile(session: session),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        AsyncError(:final error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Couldn\'t load your workouts.\n$error'),
            ),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class ActiveSessionCard extends ConsumerWidget {
  const ActiveSessionCard({super.key, required this.session});

  final WorkoutSession session;

  Future<void> _discard(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this workout?'),
        content: const Text('It will be removed from every device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(sessionsRepositoryProvider).delete(session.id);
    }
  }

  /// Finishing is what closes the loop: the session is marked done, then the
  /// engine re-reads every exercise trained and writes the next target. Doing
  /// it here rather than on the next screen means the answer is already
  /// waiting, offline included.
  Future<void> _finish(WidgetRef ref) async {
    final trained = await ref
        .read(loggingRepositoryProvider)
        .watchExercises(session.id)
        .first;
    await ref.read(sessionsRepositoryProvider).finish(session.id);

    final progression = ref.read(progressionRepositoryProvider);
    for (final exerciseId in trained.map((e) => e.exerciseId).toSet()) {
      await progression.recompute(exerciseId);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final accent = PillarColors.of(context).train;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  'IN PROGRESS',
                  style: text.labelSmall
                      ?.copyWith(color: accent, letterSpacing: 1.2),
                ),
                const Spacer(),
                _Elapsed(since: session.startedAt),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Workout started ${formatTime(session.startedAt)}',
              style: text.headlineSmall,
            ),
            const SizedBox(height: 12),
            LiveSessionExercises(sessionId: session.id),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _finish(ref),
              child: const Text('Finish workout'),
            ),
            const SizedBox(height: 4),
            Center(
              child: TextButton(
                onPressed: () => _discard(context, ref),
                child: const Text('Discard'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Minutes since [since], refreshed every 30 seconds.
class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.since});

  final DateTime since;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      formatDuration(DateTime.now().toUtc().difference(widget.since)),
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
    );
  }
}

enum _SessionAction { delete }

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session});

  final WorkoutSession session;

  /// Deleting is a soft delete that syncs, so it reaches every device and the
  /// stream filter drops the row — there is nothing local left to undo from.
  /// One stray tap in a menu should not be able to do that silently.
  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${formatDay(session.startedAt)}?'),
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
      await ref.read(sessionsRepositoryProvider).delete(session.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ended = session.endedAt!;
    return ListTile(
      title: Text(formatDay(session.startedAt)),
      subtitle: Text(
        '${formatTime(session.startedAt)} · '
        '${formatDuration(ended.difference(session.startedAt))}',
      ),
      trailing: PopupMenuButton<_SessionAction>(
        tooltip: 'More',
        // onSelected rather than PopupMenuItem.onTap: it runs once the menu
        // route has popped, so the dialog opens over the list, not the menu.
        onSelected: (action) => switch (action) {
          _SessionAction.delete => unawaited(_confirmDelete(context, ref)),
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: _SessionAction.delete,
            child: Text('Delete'),
          ),
        ],
      ),
    );
  }
}

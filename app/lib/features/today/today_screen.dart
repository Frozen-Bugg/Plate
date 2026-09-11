import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/router.dart';
import '../../app/widgets/tab_scaffold.dart';
import '../../core/auth/auth_service.dart';
import '../../core/format.dart';
import '../train/sessions_repository.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final user = ref.watch(currentUserProvider);
    final active = ref.watch(activeSessionProvider);
    final sessions = ref.watch(recentSessionsProvider).value ?? const [];

    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - DateTime.monday));
    final thisWeek = sessions
        .where((s) => s.endedAt != null && !s.startedAt.toLocal().isBefore(weekStart))
        .length;
    final name = user?.userMetadata?['full_name'] as String? ??
        user?.email?.split('@').first;

    return TabScaffold(
      title: 'Today',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            DateFormat('EEEE d MMMM').format(now).toUpperCase(),
            style: text.labelMedium?.copyWith(color: muted, letterSpacing: 1.1),
          ),
          const SizedBox(height: 4),
          Text(name == null ? 'Ready to train?' : 'Ready to train, $name?',
              style: text.headlineMedium),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    active == null
                        ? 'No workout running'
                        : 'Workout in progress since ${formatTime(active.startedAt)}',
                    style: text.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      if (active == null) {
                        await ref.read(sessionsRepositoryProvider).start();
                      }
                      if (context.mounted) context.go(Routes.train);
                    },
                    child: Text(active == null ? 'Start workout' : 'Open workout'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              title: const Text('This week'),
              trailing: Text(
                '$thisWeek ${thisWeek == 1 ? 'session' : 'sessions'}',
                style: text.titleMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

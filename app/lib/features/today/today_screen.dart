import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/router.dart';
import '../../app/theme.dart';
import '../../app/widgets/tab_scaffold.dart';
import '../../core/auth/auth_service.dart';
import '../../core/format.dart';
import '../body/activity_repository.dart';
import '../body/body_repository.dart';
import '../body/check_in_sheet.dart';
import '../body/log_weight_sheet.dart';
import '../body/recovery_repository.dart';
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
          const _ReadinessCard(),
          const SizedBox(height: 12),
          const _BodyAndMoveCard(),
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

/// This morning's readiness, or the invitation to say how it went.
class _ReadinessCard extends ConsumerWidget {
  const _ReadinessCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final today = ref.watch(todayRecoveryProvider);
    final score = today?.readiness;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showCheckInSheet(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Readiness', style: text.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      score == null
                          ? 'Ten seconds on how the morning feels'
                          : _readinessNote(score),
                      style: text.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (score == null)
                Text('Check in',
                    style: text.titleSmall?.copyWith(color: muted))
              else
                _Readout(value: '$score', unit: '/100'),
            ],
          ),
        ),
      ),
    );
  }

  /// Deliberately descriptive rather than instructive. The score shades the
  /// day; it does not change the plan, and the coach (Phase 4) is the one that
  /// gets to suggest anything.
  static String _readinessNote(int score) => switch (score) {
        >= 80 => 'Rested. Good day to chase a number.',
        >= 60 => 'Normal. Train as written.',
        >= 40 => 'Flat. Expect the last set to feel heavier.',
        _ => 'Run down. Nothing wrong with holding the load today.',
      };
}

/// Trend weight and steps — the two numbers the Body and Move pillars owe the
/// dashboard.
class _BodyAndMoveCard extends ConsumerWidget {
  const _BodyAndMoveCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final pillars = PillarColors.of(context);
    final trend = ref.watch(trendWeightProvider);
    final rate = ref.watch(weeklyRateProvider);
    final steps = ref.watch(todayStepsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: InkWell(
                onTap: () => showLogWeightSheet(context),
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Label('Trend weight', color: pillars.body),
                    const SizedBox(height: 6),
                    if (trend == null)
                      Text('Log weight', style: text.titleMedium)
                    else
                      _Readout(
                        value: formatWeight(trend).replaceAll(' kg', ''),
                        unit: 'kg',
                      ),
                    const SizedBox(height: 2),
                    Text(
                      trend == null
                          ? 'Once a day, same time'
                          : rate == null
                              ? 'Rate needs a fortnight'
                              : formatWeeklyRate(rate),
                      style: text.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Label('Steps', color: pillars.move),
                  const SizedBox(height: 6),
                  if (steps == null)
                    Text('—', style: text.headlineSmall)
                  else
                    _Readout(value: NumberFormat.decimalPattern().format(steps)),
                  const SizedBox(height: 2),
                  Text(
                    steps == null ? 'Not connected yet' : 'Today',
                    style: text.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                letterSpacing: 1,
              ),
        ),
      ],
    );
  }
}

/// A number with its unit tucked beside it, so the number is what reads.
class _Readout extends StatelessWidget {
  const _Readout({required this.value, this.unit});

  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: text.headlineSmall),
        if (unit != null) ...[
          const SizedBox(width: 3),
          Text(unit!,
              style: text.labelMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../app/widgets/tab_scaffold.dart';
import '../../core/day.dart';
import '../../core/format.dart';
import '../../core/profile/profile_repository.dart';
import '../body/activity_repository.dart';
import '../body/body_repository.dart';
import '../body/log_weight_sheet.dart';
import '../body/measurements_screen.dart';
import '../body/recovery_repository.dart';
import '../body/trend_chart.dart';

/// Progress v1: the body side of the loop. Strength curves and sets per muscle
/// join it in Phase 5, when the engine has the volume landmarks to judge them.
class ProgressScreen extends ConsumerWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final trend = ref.watch(weightTrendProvider);
    final rate = ref.watch(weeklyRateProvider);
    final latest = trend.lastOrNull;

    return TabScaffold(
      title: 'Progress',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (trend.isEmpty)
            _Empty(onLog: () => showLogWeightSheet(context))
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('TREND WEIGHT',
                                  style: text.labelSmall
                                      ?.copyWith(color: muted, letterSpacing: 1)),
                              const SizedBox(height: 4),
                              Text(formatWeight(latest!.trendKg),
                                  style: text.headlineMedium),
                              Text(
                                rate == null
                                    ? 'A fortnight of weigh-ins gives a rate'
                                    : formatWeeklyRate(rate),
                                style: text.bodySmall?.copyWith(color: muted),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => showLogWeightSheet(context),
                          child: const Text('Log'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TrendChart(points: trend),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_shortDay(trend.first.date),
                            style: text.labelSmall?.copyWith(color: muted)),
                        Text(
                            '${trend.length} '
                            '${trend.length == 1 ? 'weigh-in' : 'weigh-ins'}',
                            style: text.labelSmall?.copyWith(color: muted)),
                        Text(_shortDay(trend.last.date),
                            style: text.labelSmall?.copyWith(color: muted)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const _PhaseCard(),
          ],
          const SizedBox(height: 12),
          const _RecoveryCard(),
          const SizedBox(height: 12),
          const _StepsCard(),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              title: const Text('Measurements'),
              subtitle: const Text('Waist, chest, arms — monthly is plenty'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const MeasurementsScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _shortDay(DateTime date) =>
      '${date.day}/${date.month.toString().padLeft(2, '0')}';
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onLog});

  final VoidCallback onLog;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Trends, not noise', style: text.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Weigh in daily, at the same time, and the line settles within a '
              'week. Any single morning is mostly water — the smoothed trend is '
              'the part worth reacting to.',
              style: text.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onLog, child: const Text('Log weight')),
          ],
        ),
      ),
    );
  }
}

/// Whether the trend is doing what the phase asks of it.
///
/// The verdict comes from the engine's bands (docs/PLAN.md §6). It stays quiet
/// until there is enough history to mean something, because the next thing to
/// read it will be a calorie proposal.
class _PhaseCard extends ConsumerWidget {
  const _PhaseCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final trend = ref.watch(weightTrendProvider);
    final phase = ref.watch(weightPhaseProvider);
    final verdict = engine.judgeTrend(trend, phase);
    if (verdict == engine.TrendVerdict.unknown) return const SizedBox.shrink();

    final pillars = PillarColors.of(context);
    final (label, note) = switch ((phase, verdict)) {
      (_, engine.TrendVerdict.onTarget) => ('On target', _band(phase)),
      (engine.WeightPhase.cut, engine.TrendVerdict.above) =>
        ('Losing slower than planned', _band(phase)),
      (engine.WeightPhase.cut, engine.TrendVerdict.below) =>
        ('Losing faster than planned', 'Fast loss costs muscle. ${_band(phase)}'),
      (engine.WeightPhase.bulk, engine.TrendVerdict.above) =>
        ('Gaining faster than planned', 'Most of the excess is fat. ${_band(phase)}'),
      (engine.WeightPhase.bulk, engine.TrendVerdict.below) =>
        ('Gaining slower than planned', _band(phase)),
      (_, engine.TrendVerdict.above) => ('Drifting up', _band(phase)),
      (_, engine.TrendVerdict.below) => ('Drifting down', _band(phase)),
      _ => ('', ''),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: verdict == engine.TrendVerdict.onTarget
                    ? pillars.fuel
                    : pillars.move,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: text.titleSmall),
                  const SizedBox(height: 2),
                  Text(note, style: text.bodySmall?.copyWith(color: muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _band(engine.WeightPhase phase) {
    final low = phase.minPercentPerWeek.abs();
    final high = phase.maxPercentPerWeek.abs();
    return switch (phase) {
      engine.WeightPhase.cut => 'A cut aims for $high–$low% of bodyweight a week.',
      engine.WeightPhase.bulk => 'A lean bulk aims for $low–$high% a week.',
      engine.WeightPhase.maintain => 'Maintenance allows ±$high% a week.',
    };
  }
}

class _RecoveryCard extends ConsumerWidget {
  const _RecoveryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final days = ref.watch(recentRecoveryProvider).value ?? const [];
    final scored = days.where((d) => d.readiness != null).toList();
    if (scored.isEmpty) return const SizedBox.shrink();

    final week = scored.where((d) => d.recoveredOn.compareTo(daysAgo(7)) >= 0);
    final average = week.isEmpty
        ? null
        : (week.map((d) => d.readiness!).reduce((a, b) => a + b) / week.length)
            .round();

    return Card(
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
                    average == null
                        ? 'No check-ins this week'
                        : 'Averaging $average over the last week',
                    style: text.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            _Sparks(
              values: [
                for (final d in scored.take(14)) d.readiness!.toDouble(),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepsCard extends ConsumerWidget {
  const _StepsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final average = ref.watch(stepAverageProvider(7));

    return Card(
      child: ListTile(
        title: const Text('Steps'),
        subtitle: Text(
          average == null
              ? 'Connect Health to bring steps in'
              : 'Averaging $average a day this week',
          style: text.bodySmall?.copyWith(color: muted),
        ),
      ),
    );
  }
}

/// A bar per day, tall for good. Small enough to read at a glance and not
/// pretend to be a chart.
class _Sparks extends StatelessWidget {
  const _Sparks({required this.values});

  final List<double> values;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 32,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in values)
            Padding(
              padding: const EdgeInsets.only(left: 3),
              child: Container(
                width: 5,
                height: (v / 100 * 32).clamp(3, 32),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.25 + v / 100 * 0.75),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../app/widgets/tab_scaffold.dart';
import '../../core/day.dart';
import '../../core/format.dart';
import '../../core/profile/profile_repository.dart';
import '../body/activity_repository.dart';
import '../body/body_repository.dart';
import '../body/health_connect_tile.dart';
import '../body/health_import.dart';
import '../body/log_weight_sheet.dart';
import '../body/measurements_screen.dart';
import '../body/photos_screen.dart';
import '../body/recovery_repository.dart';
import '../body/rollup_repository.dart';
import '../body/trend_chart.dart';
import '../fuel/targets_repository.dart';

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
          const _FuelCard(),
          const SizedBox(height: 12),
          const _TrainingCard(),
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
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              title: const Text('Progress photos'),
              subtitle: const Text('Private — same light, same spot'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PhotosScreen()),
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
    final connected = ref.watch(healthPermittedProvider).value ?? false;

    return Card(
      child: ListTile(
        title: const Text('Steps'),
        subtitle: Text(
          switch ((average, connected)) {
            (final int days, _) => 'Averaging $days a day this week',
            (_, true) => 'Connected — nothing counted yet',
            (_, false) => 'Connect Health to bring steps in',
          },
          style: text.bodySmall?.copyWith(color: muted),
        ),
        trailing: connected ? null : const Icon(Icons.chevron_right),
        onTap: connected ? null : () => connectHealth(context, ref),
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

/// What the week actually added up to in the gym.
///
/// Read from daily_rollup rather than recounted here: the rollup is the record
/// of the day, and a second implementation of "what is a hard set" is a second
/// answer waiting to disagree with the first.
class _TrainingCard extends ConsumerWidget {
  const _TrainingCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final rollups = ref.watch(dailyRollupsProvider).value ?? const [];
    final week = rollups.where((r) => r.rollupOn.compareTo(daysAgo(6)) >= 0);

    final sets = week.fold(0, (total, r) => total + (r.hardSets ?? 0));
    final volume = week.fold(0.0, (total, r) => total + (r.volumeKg ?? 0));
    if (sets == 0) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Training', style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text('Last seven days',
                      style: text.bodySmall?.copyWith(color: muted)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$sets ${sets == 1 ? 'hard set' : 'hard sets'}',
                    style: text.titleMedium),
                Text(
                  '${NumberFormat.decimalPattern().format(volume.round())} kg lifted',
                  style: text.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Intake against maintenance, which is the pair of numbers a phase lives or
/// dies by.
///
/// Read from daily_rollup rather than recounted: the rollup is the record of
/// the day, and the estimate stored on it is what the engine believed at the
/// time rather than what it believes now.
class _FuelCard extends ConsumerWidget {
  const _FuelCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final rollups = ref.watch(dailyRollupsProvider).value ?? const [];
    final week = rollups
        .where((r) => r.rollupOn.compareTo(daysAgo(6)) >= 0)
        .where((r) => (r.intakeKcal ?? 0) > 0)
        .toList();
    if (week.isEmpty) return const SizedBox.shrink();

    final average =
        week.map((r) => r.intakeKcal!).reduce((a, b) => a + b) / week.length;
    final tdee = ref.watch(tdeeProvider).value;
    final maintenance = tdee != null && tdee.kcal > 0 ? tdee.kcal : null;
    final gap = maintenance == null ? null : average - maintenance;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Fuel', style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    // Days without a log are left out rather than counted as
                    // zero — the same rule the engine uses, for the same reason.
                    '${week.length} of the last 7 days logged',
                    style: text.bodySmall?.copyWith(color: muted),
                  ),
                  if (gap != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      switch (gap) {
                        < -50 =>
                          '${gap.abs().round()} kcal a day under maintenance',
                        > 50 => '${gap.round()} kcal a day over maintenance',
                        _ => 'About maintenance',
                      },
                      style: text.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${average.round()} kcal', style: text.titleMedium),
                if (maintenance != null)
                  Text(
                    tdee!.isMeasured
                        ? 'burning ~$maintenance'
                        : 'estimating ~$maintenance',
                    style: text.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

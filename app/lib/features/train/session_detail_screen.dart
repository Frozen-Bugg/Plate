import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/db/app_database.dart';
import '../../core/format.dart';
import 'exercises_repository.dart';
import 'logging_repository.dart';

/// A finished workout, set by set.
///
/// The thing the history list was missing. "Sat 12 Sep · 52 min" says a workout
/// happened; this says what it was, which is the only version worth keeping —
/// for settling what you squatted last Tuesday, and for seeing that the third
/// set has been 8 reps for three weeks.
class SessionDetailScreen extends ConsumerWidget {
  const SessionDetailScreen({super.key, required this.session});

  final WorkoutSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final logged = ref.watch(sessionDetailProvider(session.id));
    final summary =
        ref.watch(sessionSummariesProvider).value?[session.id] ?? emptySummary;
    final ended = session.endedAt;

    return Scaffold(
      appBar: AppBar(title: Text(formatDay(session.startedAt))),
      body: switch (logged) {
        AsyncError(:final error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text("Couldn't read this workout.\n$error"),
            ),
          ),
        AsyncData(:final value) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Text(
                [
                  formatTime(session.startedAt),
                  if (ended != null)
                    formatDuration(ended.difference(session.startedAt)),
                ].join(' · '),
                style: text.bodyMedium?.copyWith(color: muted),
              ),
              const SizedBox(height: 16),
              _Totals(summary: summary),
              const SizedBox(height: 20),
              if (value.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'Nothing was logged in this one.',
                    style: text.bodyMedium?.copyWith(color: muted),
                  ),
                ),
              for (final entry in value)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _LoggedExerciseCard(entry: entry),
                ),
            ],
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// The three numbers that describe a session at a glance.
class _Totals extends StatelessWidget {
  const _Totals({required this.summary});

  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Row(
          children: [
            _Stat(
              label: 'Exercises',
              value: '${summary.exerciseIds.length}',
            ),
            _Stat(label: 'Sets', value: '${summary.setCount}'),
            _Stat(
              label: 'Volume',
              // Tonnes past a thousand kilos: five figures of kilograms is a
              // number nobody reads.
              value: summary.volumeKg >= 1000
                  ? '${(summary.volumeKg / 1000).toStringAsFixed(1)} t'
                  : '${summary.volumeKg.round()} kg',
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: text.titleLarge?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            label.toUpperCase(),
            style: text.labelSmall?.copyWith(color: muted, letterSpacing: 1),
          ),
        ],
      ),
    );
  }
}

/// One exercise and every set logged against it.
class _LoggedExerciseCard extends ConsumerWidget {
  const _LoggedExerciseCard({required this.entry});

  final LoggedExercise entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final name = ref.watch(exerciseByIdProvider(entry.exercise.exerciseId));
    final sets = entry.sets;

    final volume = sets.fold<double>(
      0,
      (sum, s) => sum + (s.weightKg ?? 0) * (s.reps ?? 0),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  // The name is looked up, but the sets below render from what
                  // they stored: a movement removed from the library later does
                  // not erase the workout it was in.
                  child: Text(name?.name ?? 'Exercise', style: text.titleMedium),
                ),
                Text(
                  sets.isEmpty
                      ? 'no sets'
                      : '${sets.length} ${sets.length == 1 ? 'set' : 'sets'} · '
                          '${volume.round()} kg',
                  style: text.labelMedium?.copyWith(color: muted),
                ),
              ],
            ),
            if (sets.isNotEmpty) const SizedBox(height: 8),
            for (final set in sets) _DetailSetRow(set: set),
          ],
        ),
      ),
    );
  }
}

class _DetailSetRow extends StatelessWidget {
  const _DetailSetRow({required this.set});

  final WorkoutSet set;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final weight = set.weightKg;
    final reps = set.reps;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '${set.setIndex + 1}',
              style: text.labelMedium?.copyWith(color: muted),
            ),
          ),
          Expanded(
            child: Text(
              weight == null || reps == null
                  ? '—'
                  : '${formatWeight(weight)} × $reps'
                      '${set.rir == null ? '' : '  @${formatRir(set.rir!)}'}',
              style: text.bodyLarge?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (set.isPr)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'PR',
                style: text.labelMedium?.copyWith(
                  color: PillarColors.of(context).move,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          if (set.e1rmKg case final e?)
            Text(
              'e1RM ${formatWeight(e)}',
              style: text.labelSmall?.copyWith(color: muted),
            ),
        ],
      ),
    );
  }
}

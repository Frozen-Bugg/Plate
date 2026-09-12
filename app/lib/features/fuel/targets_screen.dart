import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/profile/profile_repository.dart';
import '../body/body_repository.dart';
import 'targets_repository.dart';

/// Where the day's numbers come from, and the one dial worth turning.
///
/// The engine does the arithmetic; this screen shows its working and asks for
/// approval. Nothing is stored until Save — a target that changed itself while
/// being read would be a target nobody could trust.
class TargetsScreen extends ConsumerStatefulWidget {
  const TargetsScreen({super.key});

  @override
  ConsumerState<TargetsScreen> createState() => _TargetsScreenState();
}

class _TargetsScreenState extends ConsumerState<TargetsScreen> {
  /// 0 is the gentle end of the phase's band, 1 the aggressive end. Starts in
  /// the middle, which is where a sensible range should start.
  double _intensity = 0.5;
  var _saving = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final scheme = Theme.of(context).colorScheme;

    final tdee = ref.watch(tdeeProvider).value;
    final bmr = ref.watch(bmrProvider);
    final phase = ref.watch(weightPhaseProvider);
    final weightKg = ref.watch(trendWeightProvider);
    final current = ref.watch(todayTargetProvider);

    if (tdee == null || bmr == null || weightKg == null || tdee.kcal <= 0) {
      return Scaffold(
        appBar: AppBar(title: const Text('Targets')),
        body: _Missing(
          hasWeight: weightKg != null,
          hasProfile: bmr != null,
        ),
      );
    }

    final target = engine.dailyTarget(
      tdeeKcal: tdee.kcal,
      phase: phase,
      weightKg: weightKg,
      bmrKcal: bmr,
      intensity: _intensity,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Targets')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tdee.isMeasured ? 'MEASURED' : 'ESTIMATING',
                    style: text.labelSmall
                        ?.copyWith(color: muted, letterSpacing: 1.2),
                  ),
                  const SizedBox(height: 4),
                  Text('${tdee.kcal.round()} kcal a day',
                      style: text.headlineMedium),
                  const SizedBox(height: 2),
                  Text(
                    switch (tdee.status) {
                      engine.TdeeStatus.measured =>
                        'From ${tdee.loggedDays} days of food against what the '
                            'scale did. This is your number, not a formula.',
                      engine.TdeeStatus.notEnoughLogs =>
                        'Holding the last figure: under five of the last seven '
                            'days were logged, and half a week of food is not '
                            'something to re-estimate from.',
                      engine.TdeeStatus.estimating =>
                        'From your height, age, sex and step count. Two weeks '
                            'of food logs replaces it with a measurement.',
                    },
                    style: text.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('PHASE', style: text.labelSmall?.copyWith(color: muted, letterSpacing: 1.2)),
          const SizedBox(height: 4),
          Text(
            switch (phase) {
              engine.WeightPhase.cut => 'Cutting — eating under maintenance',
              engine.WeightPhase.maintain => 'Maintaining — eating at it',
              engine.WeightPhase.bulk => 'Lean bulk — eating over it',
            },
            style: text.titleMedium,
          ),
          Text('Change it in Settings.',
              style: text.bodySmall?.copyWith(color: muted)),
          if (phase != engine.WeightPhase.maintain) ...[
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Pace', style: text.titleSmall),
                Text(
                  switch (_intensity) {
                    < 0.34 => 'Gentle',
                    < 0.67 => 'Middle',
                    _ => 'Aggressive',
                  },
                  style: text.labelLarge?.copyWith(color: muted),
                ),
              ],
            ),
            Slider(
              value: _intensity,
              onChanged: (v) => setState(() => _intensity = v),
            ),
            Text(
              phase == engine.WeightPhase.cut
                  ? 'A bigger deficit is faster and costs more muscle. The '
                      'gentle end is what holds your lifts.'
                  : 'A bigger surplus is faster and more of it is fat.',
              style: text.bodySmall?.copyWith(color: muted),
            ),
          ],
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('${target.kcal}', style: text.displaySmall),
                      const SizedBox(width: 6),
                      Text('kcal a day',
                          style: text.labelLarge?.copyWith(color: muted)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _Macro(label: 'Protein', grams: target.proteinG),
                  _Macro(label: 'Carbs', grams: target.carbG),
                  _Macro(label: 'Fat', grams: target.fatG),
                  if (target.flooredAtBmr) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Held at your resting burn. The phase asked for less than '
                      'that, and the engine will not propose eating below what '
                      'your body uses lying still.',
                      style: text.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Protein first, fat to its floor, carbohydrate takes the rest — it '
            'is the fuel for the training, and the training is the point. '
            'Every number is editable once saved.',
            style: text.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : () => _save(target, tdee),
            child: Text(current == null ? 'Set targets' : 'Update targets'),
          ),
        ],
      ),
    );
  }

  Future<void> _save(engine.MacroTarget target, engine.TdeeEstimate tdee) async {
    setState(() => _saving = true);
    await ref.read(targetsRepositoryProvider).save(
          target: target,
          tdeeKcal: tdee.kcal.round(),
        );
    if (mounted) Navigator.of(context).pop();
  }
}

class _Macro extends StatelessWidget {
  const _Macro({required this.label, required this.grams});

  final String label;
  final int grams;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: text.bodyMedium),
          Text('$grams g', style: text.titleSmall),
        ],
      ),
    );
  }
}

/// Says exactly what is missing, rather than showing an empty screen.
class _Missing extends StatelessWidget {
  const _Missing({required this.hasWeight, required this.hasProfile});

  final bool hasWeight;
  final bool hasProfile;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Not enough to go on', style: text.headlineSmall),
            const SizedBox(height: 8),
            Text(
              [
                if (!hasWeight) 'a weigh-in',
                if (!hasProfile) 'your height, year of birth and sex',
              ].join(' and '),
              textAlign: TextAlign.center,
              style: text.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Resting burn is where a calorie target starts from, and it needs '
              'those. The app will not guess them.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

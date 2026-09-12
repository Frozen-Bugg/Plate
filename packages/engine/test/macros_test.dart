import 'package:engine/engine.dart';
import 'package:test/test.dart';

DateTime day(int n) => DateTime.utc(2026, 9, n);

List<TrendPoint> movingAt(double percentPerWeek, {double start = 80}) {
  final perDay = start * percentPerWeek / 100 / 7;
  return weightTrend([
    for (var i = 0; i < 40; i++)
      WeighIn(date: day(1).add(Duration(days: i)), weightKg: start + i * perDay),
  ]);
}

void main() {
  group('dailyTarget', () {
    test('maintenance eats at maintenance', () {
      final target = dailyTarget(
        tdeeKcal: 2800,
        phase: WeightPhase.maintain,
        weightKg: 80,
        bmrKcal: 1780,
      );
      expect(target.kcal, 2800);
      expect(target.flooredAtBmr, isFalse);
    });

    test('a cut takes the spec band off maintenance', () {
      final gentle = dailyTarget(
        tdeeKcal: 2800,
        phase: WeightPhase.cut,
        weightKg: 80,
        bmrKcal: 1780,
        intensity: 0,
      );
      final hard = dailyTarget(
        tdeeKcal: 2800,
        phase: WeightPhase.cut,
        weightKg: 80,
        bmrKcal: 1780,
        intensity: 1,
      );
      expect(gentle.kcal, 2500);
      expect(hard.kcal, 2300);
    });

    test('a lean bulk adds it', () {
      final gentle = dailyTarget(
        tdeeKcal: 2800,
        phase: WeightPhase.bulk,
        weightKg: 80,
        bmrKcal: 1780,
        intensity: 0,
      );
      final hard = dailyTarget(
        tdeeKcal: 2800,
        phase: WeightPhase.bulk,
        weightKg: 80,
        bmrKcal: 1780,
        intensity: 1,
      );
      expect(gentle.kcal, 2950);
      expect(hard.kcal, 3100);
    });

    test('the middle of the band is the default', () {
      final target = dailyTarget(
        tdeeKcal: 2800,
        phase: WeightPhase.cut,
        weightKg: 80,
        bmrKcal: 1780,
      );
      expect(target.kcal, 2400);
    });

    test('protein is highest on a cut, where it matters most', () {
      double protein(WeightPhase phase) => dailyTarget(
            tdeeKcal: 2800,
            phase: phase,
            weightKg: 80,
            bmrKcal: 1780,
            intensity: 1,
          ).proteinG.toDouble();

      expect(protein(WeightPhase.cut), 80 * 2.4);
      expect(protein(WeightPhase.maintain), 80 * 2.2);
      expect(protein(WeightPhase.bulk), 80 * 2.0);
      expect(protein(WeightPhase.cut),
          greaterThan(protein(WeightPhase.bulk)));
    });

    test('fat clears the hormonal floor', () {
      final target = dailyTarget(
        tdeeKcal: 2800,
        phase: WeightPhase.cut,
        weightKg: 80,
        bmrKcal: 1780,
      );
      expect(target.fatG, greaterThanOrEqualTo((80 * 0.6).round()));
    });

    test('refuses a fat target below the floor rather than quietly raising it', () {
      expect(
        () => dailyTarget(
          tdeeKcal: 2800,
          phase: WeightPhase.cut,
          weightKg: 80,
          bmrKcal: 1780,
          fatPerKg: 0.4,
        ),
        throwsArgumentError,
      );
    });

    test('carbohydrate takes what is left', () {
      final target = dailyTarget(
        tdeeKcal: 2800,
        phase: WeightPhase.maintain,
        weightKg: 80,
        bmrKcal: 1780,
      );
      expect(target.kcalFromMacros, closeTo(target.kcal, 10));
    });

    test('never proposes eating below resting burn', () {
      // A small, light person on the most aggressive cut the app allows.
      final target = dailyTarget(
        tdeeKcal: 1700,
        phase: WeightPhase.cut,
        weightKg: 50,
        bmrKcal: 1400,
        intensity: 1,
      );
      expect(target.kcal, 1400);
      expect(target.flooredAtBmr, isTrue);
    });

    test('says when it floored, so the UI can explain itself', () {
      final normal = dailyTarget(
        tdeeKcal: 2800,
        phase: WeightPhase.cut,
        weightKg: 80,
        bmrKcal: 1780,
      );
      expect(normal.flooredAtBmr, isFalse);
    });

    test('reports no carbohydrate rather than a negative target', () {
      // Protein and fat alone can exceed a floored target for a heavy lifter
      // on a deep cut.
      final target = dailyTarget(
        tdeeKcal: 1500,
        phase: WeightPhase.cut,
        weightKg: 120,
        bmrKcal: 1200,
        intensity: 1,
      );
      expect(target.carbG, greaterThanOrEqualTo(0));
    });

    test('rejects an intensity outside the band', () {
      expect(
        () => dailyTarget(
          tdeeKcal: 2800,
          phase: WeightPhase.cut,
          weightKg: 80,
          bmrKcal: 1780,
          intensity: 1.5,
        ),
        throwsArgumentError,
      );
    });

    test('rejects an impossible bodyweight', () {
      expect(
        () => dailyTarget(
          tdeeKcal: 2800,
          phase: WeightPhase.cut,
          weightKg: 0,
          bmrKcal: 1780,
        ),
        throwsArgumentError,
      );
    });
  });

  group('proposeCalorieChange', () {
    test('says nothing while the trend is on target', () {
      expect(
        proposeCalorieChange(
          trend: movingAt(-0.75),
          phase: WeightPhase.cut,
          currentKcal: 2400,
        ),
        isNull,
      );
    });

    test('says nothing without enough history to judge', () {
      expect(
        proposeCalorieChange(
          trend: weightTrend([WeighIn(date: day(1), weightKg: 80)]),
          phase: WeightPhase.cut,
          currentKcal: 2400,
        ),
        isNull,
      );
    });

    test('cuts calories when a cut has stopped moving', () {
      final proposal = proposeCalorieChange(
        trend: movingAt(0),
        phase: WeightPhase.cut,
        currentKcal: 2400,
      );
      expect(proposal, isNotNull);
      expect(proposal!.deltaKcal, lessThan(0));
      expect(proposal.toKcal, lessThan(2400));
    });

    test('adds calories when a bulk is not gaining', () {
      final proposal = proposeCalorieChange(
        trend: movingAt(0),
        phase: WeightPhase.bulk,
        currentKcal: 3000,
      );
      expect(proposal, isNotNull);
      expect(proposal!.deltaKcal, greaterThan(0));
    });

    test('adds calories when a cut is losing too fast', () {
      final proposal = proposeCalorieChange(
        trend: movingAt(-1.5),
        phase: WeightPhase.cut,
        currentKcal: 2400,
      );
      expect(proposal, isNotNull);
      expect(proposal!.deltaKcal, greaterThan(0));
    });

    test('takes calories away from a bulk running away with itself', () {
      final proposal = proposeCalorieChange(
        trend: movingAt(1.5),
        phase: WeightPhase.bulk,
        currentKcal: 3000,
      );
      expect(proposal, isNotNull);
      expect(proposal!.deltaKcal, lessThan(0));
    });

    test('stays inside the spec 100-150 kcal step, however wild the fortnight', () {
      for (final rate in [-4.0, -2.0, 0.0, 2.0, 4.0]) {
        for (final phase in WeightPhase.values) {
          final proposal = proposeCalorieChange(
            trend: movingAt(rate),
            phase: phase,
            currentKcal: 2500,
          );
          if (proposal == null) continue;
          expect(proposal.deltaKcal.abs(), greaterThanOrEqualTo(100));
          expect(proposal.deltaKcal.abs(), lessThanOrEqualTo(150));
        }
      }
    });

    test('carries the numbers the coach has to show its working with', () {
      final proposal = proposeCalorieChange(
        trend: movingAt(0),
        phase: WeightPhase.cut,
        currentKcal: 2400,
      )!;
      expect(proposal.fromKcal, 2400);
      expect(proposal.observedRatePercent, closeTo(0, 0.05));
      expect(proposal.targetRatePercent, WeightPhase.cut.maxPercentPerWeek);
    });
  });
}

import 'package:engine/engine.dart';
import 'package:test/test.dart';

DateTime day(int n) => DateTime.utc(2026, 9, n);

/// A trend moving at [kgPerWeek], long enough for the rate to be fitted.
List<TrendPoint> movingAt(double kgPerWeek, {double start = 80, int days = 15}) {
  final perDay = kgPerWeek / 7;
  return weightTrend([
    for (var i = 0; i < days; i++)
      WeighIn(date: day(i + 1), weightKg: start + i * perDay),
  ]);
}

/// [days] of logs ending on the last day of the trend, which is where a real
/// food log lives — the recent days are the ones people have written down.
List<IntakeDay> eating(int kcal, {int days = 15}) => [
      for (var i = 0; i < days; i++) IntakeDay(date: day(15 - i), kcal: kcal),
    ];

void main() {
  group('basalMetabolicRate', () {
    test('is Mifflin-St Jeor', () {
      // 10*80 + 6.25*180 - 5*30 + 5 = 1780
      expect(
        basalMetabolicRate(
            weightKg: 80, heightCm: 180, ageYears: 30, sex: Sex.male),
        closeTo(1780, 1e-9),
      );
      // 10*65 + 6.25*165 - 5*30 - 161 = 1370.25
      expect(
        basalMetabolicRate(
            weightKg: 65, heightCm: 165, ageYears: 30, sex: Sex.female),
        closeTo(1370.25, 1e-9),
      );
    });

    test('the sex term is the only difference, and it is 166 kcal', () {
      final male = basalMetabolicRate(
          weightKg: 80, heightCm: 180, ageYears: 30, sex: Sex.male);
      final female = basalMetabolicRate(
          weightKg: 80, heightCm: 180, ageYears: 30, sex: Sex.female);
      expect(male - female, closeTo(166, 1e-9));
    });

    test('falls with age', () {
      final young = basalMetabolicRate(
          weightKg: 80, heightCm: 180, ageYears: 20, sex: Sex.male);
      final older = basalMetabolicRate(
          weightKg: 80, heightCm: 180, ageYears: 60, sex: Sex.male);
      expect(young - older, closeTo(200, 1e-9));
    });

    test('rejects impossible inputs', () {
      expect(
        () => basalMetabolicRate(
            weightKg: 0, heightCm: 180, ageYears: 30, sex: Sex.male),
        throwsArgumentError,
      );
      expect(
        () => basalMetabolicRate(
            weightKg: 80, heightCm: 0, ageYears: 30, sex: Sex.male),
        throwsArgumentError,
      );
      expect(
        () => basalMetabolicRate(
            weightKg: 80, heightCm: 180, ageYears: -1, sex: Sex.male),
        throwsArgumentError,
      );
    });
  });

  group('Sex', () {
    test('round-trips the value stored in profiles.sex', () {
      for (final sex in Sex.values) {
        expect(Sex.fromWire(sex.wireName), sex);
      }
    });

    test('is null rather than throwing for an unset or unknown profile', () {
      expect(Sex.fromWire(null), isNull);
      expect(Sex.fromWire(''), isNull);
      expect(Sex.fromWire('unspecified'), isNull);
    });
  });

  group('activityFactor', () {
    test('sits on the familiar rungs', () {
      expect(activityFactor(0), closeTo(1.2, 1e-9));
      expect(activityFactor(5000), closeTo(1.375, 1e-9));
      expect(activityFactor(7500), closeTo(1.55, 1e-9));
      expect(activityFactor(10000), closeTo(1.725, 1e-9));
      expect(activityFactor(12500), closeTo(1.9, 1e-9));
    });

    test('interpolates between them, so no step is a cliff', () {
      final below = activityFactor(7499);
      final above = activityFactor(7500);
      expect((above - below).abs(), lessThan(0.001));
      expect(activityFactor(6250), closeTo(1.4625, 1e-9));
    });

    test('rises with steps, always', () {
      var previous = activityFactor(0);
      for (var steps = 500; steps <= 12500; steps += 500) {
        final factor = activityFactor(steps);
        expect(factor, greaterThan(previous));
        previous = factor;
      }
    });

    test('caps at the top rung', () {
      expect(activityFactor(20000), closeTo(1.9, 1e-9));
      expect(activityFactor(100000), closeTo(1.9, 1e-9));
    });

    test('rejects a negative count', () {
      expect(() => activityFactor(-1), throwsArgumentError);
    });
  });

  group('seedTdee', () {
    test('is resting burn times how much they move', () {
      final seed = seedTdee(
        weightKg: 80,
        heightCm: 180,
        ageYears: 30,
        sex: Sex.male,
        stepsPerDay: 10000,
      );
      expect(seed, closeTo(1780 * 1.725, 1e-9));
    });

    test('assumes sedentary when nothing is counting steps', () {
      final seed = seedTdee(
          weightKg: 80, heightCm: 180, ageYears: 30, sex: Sex.male);
      expect(seed, closeTo(1780 * 1.2, 1e-9));
    });
  });

  group('observedTdee', () {
    test('adds back what the weight loss must have cost', () {
      // Half a kilo a week is 3850 kcal over seven days: 550 a day.
      expect(
        observedTdee(averageIntakeKcal: 2400, weeklyRateKg: -0.5),
        closeTo(2950, 1e-9),
      );
    });

    test('subtracts what a gain must have been built from', () {
      expect(
        observedTdee(averageIntakeKcal: 3000, weeklyRateKg: 0.25),
        closeTo(3000 - 275, 1e-9),
      );
    });

    test('is just intake when the scale is flat', () {
      expect(
        observedTdee(averageIntakeKcal: 2500, weeklyRateKg: 0),
        closeTo(2500, 1e-9),
      );
    });
  });

  group('dampedTdee', () {
    test('moves a quarter of the way by default', () {
      expect(dampedTdee(previous: 2400, observed: 2800), closeTo(2500, 1e-9));
    });

    test('a single odd week barely moves it', () {
      expect(
        (dampedTdee(previous: 2500, observed: 3500) - 2500).abs(),
        lessThan(260),
      );
    });

    test('a sustained change gets most of the way within a month', () {
      var estimate = 2500.0;
      for (var week = 0; week < 4; week++) {
        estimate = dampedTdee(previous: estimate, observed: 2900);
      }
      expect(estimate, greaterThan(2750));
    });

    test('rejects a damping factor outside (0, 1]', () {
      expect(() => dampedTdee(previous: 2500, observed: 2600, damping: 0),
          throwsArgumentError);
      expect(() => dampedTdee(previous: 2500, observed: 2600, damping: 1.5),
          throwsArgumentError);
    });
  });

  group('estimateTdee', () {
    test('uses the seed while there is nothing to measure', () {
      final estimate = estimateTdee(
        intake: const [],
        trend: const [],
        seed: 2600,
      );
      expect(estimate.kcal, 2600);
      expect(estimate.status, TdeeStatus.estimating);
      expect(estimate.isMeasured, isFalse);
    });

    test('still estimates when the food log is patchy', () {
      final estimate = estimateTdee(
        intake: eating(2400, days: 4),
        trend: movingAt(-0.5),
        seed: 2600,
      );
      expect(estimate.status, TdeeStatus.estimating);
      expect(estimate.kcal, 2600);
      expect(estimate.loggedDays, 4);
    });

    test('measures once a fortnight of logs exists', () {
      final estimate = estimateTdee(
        intake: eating(2400),
        trend: movingAt(-0.5),
        seed: 2600,
      );
      expect(estimate.status, TdeeStatus.measured);
      // Eating 2400 while losing half a kilo a week means burning ~2950.
      expect(estimate.kcal, closeTo(2950, 20));
    });

    test('damps against a previous figure rather than replacing it', () {
      final fresh = estimateTdee(
        intake: eating(2400),
        trend: movingAt(-0.5),
        seed: 2600,
      );
      final damped = estimateTdee(
        intake: eating(2400),
        trend: movingAt(-0.5),
        seed: 2600,
        previous: 2600,
      );
      expect(damped.kcal, lessThan(fresh.kcal));
      expect(damped.kcal, closeTo(2600 + (fresh.kcal - 2600) * 0.25, 1e-6));
    });

    test('holds the previous figure when the week is half logged', () {
      // Enough days in the fortnight to measure from, but they are the older
      // ones: the window runs from the 2nd, so these ten reach only the 11th
      // and just three of them fall in the last seven days.
      final estimate = estimateTdee(
        intake: [
          for (var i = 2; i <= 11; i++) IntakeDay(date: day(i), kcal: 2400),
        ],
        trend: movingAt(-0.5),
        seed: 2600,
        previous: 2700,
      );
      expect(estimate.status, TdeeStatus.notEnoughLogs);
      expect(estimate.kcal, 2700);
      expect(estimate.loggedDays, 10);
    });

    test('does not count days outside the window', () {
      final estimate = estimateTdee(
        intake: [
          for (var i = 0; i < 20; i++)
            IntakeDay(date: DateTime.utc(2026, 8, i + 1), kcal: 2400),
          ...eating(2400),
        ],
        trend: movingAt(-0.5),
        seed: 2600,
      );
      expect(estimate.loggedDays, lessThanOrEqualTo(14));
    });

    test('a bulk measures higher than the intake, not lower', () {
      final estimate = estimateTdee(
        intake: eating(3200),
        trend: movingAt(0.25),
        seed: 2600,
      );
      expect(estimate.status, TdeeStatus.measured);
      expect(estimate.kcal, lessThan(3200));
      expect(estimate.kcal, closeTo(3200 - 275, 30));
    });
  });
}

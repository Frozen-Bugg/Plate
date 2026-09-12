import 'package:engine/engine.dart';
import 'package:test/test.dart';

void main() {
  group('readinessScore', () {
    test('is null when the lifter answered nothing and wears nothing', () {
      expect(readinessScore(), isNull);
      expect(
        readinessScore(checkIn: const CheckIn(), signals: const RecoverySignals()),
        isNull,
      );
    });

    test('a perfect morning scores 100', () {
      expect(
        readinessScore(
          checkIn: const CheckIn(sleepQuality: 5, soreness: 1, stress: 1, energy: 5),
        ),
        100,
      );
    });

    test('the worst morning scores 0', () {
      expect(
        readinessScore(
          checkIn: const CheckIn(sleepQuality: 1, soreness: 5, stress: 5, energy: 1),
        ),
        0,
      );
    });

    test('an average morning sits in the middle', () {
      expect(
        readinessScore(
          checkIn: const CheckIn(sleepQuality: 3, soreness: 3, stress: 3, energy: 3),
        ),
        50,
      );
    });

    test('soreness and stress run the other way', () {
      final fresh = readinessScore(checkIn: const CheckIn(soreness: 1))!;
      final wrecked = readinessScore(checkIn: const CheckIn(soreness: 5))!;
      expect(fresh, greaterThan(wrecked));
      expect(fresh, 100);
      expect(wrecked, 0);
    });

    test('missing answers are dropped, not counted as neutral', () {
      // Energy alone at 5 is a full score, not 20% of one.
      expect(readinessScore(checkIn: const CheckIn(energy: 5)), 100);
    });

    test('rejects an answer outside 1-5', () {
      expect(() => readinessScore(checkIn: const CheckIn(energy: 0)),
          throwsArgumentError);
      expect(() => readinessScore(checkIn: const CheckIn(energy: 6)),
          throwsArgumentError);
    });

    test('scores a night from the watch with no check-in at all', () {
      final score = readinessScore(
        signals: const RecoverySignals(sleepMinutes: 480, hrvMs: 60, restingHr: 50),
        baseline: const RecoveryBaseline(hrvMs: 60, restingHr: 50),
      );
      // Full sleep, both signals exactly at baseline.
      expect(score, 69);
    });

    test('a short night pulls the score down', () {
      const rested = RecoverySignals(sleepMinutes: 480);
      const short = RecoverySignals(sleepMinutes: 300);
      expect(readinessScore(signals: rested), 100);
      expect(readinessScore(signals: short), 40);
    });

    test('sleeping past the target is not a penalty', () {
      expect(readinessScore(signals: const RecoverySignals(sleepMinutes: 600)), 100);
    });

    test('HRV is read against the lifter own baseline', () {
      const baseline = RecoveryBaseline(hrvMs: 50);
      expect(
        readinessScore(signals: const RecoverySignals(hrvMs: 50), baseline: baseline),
        50,
      );
      expect(
        readinessScore(signals: const RecoverySignals(hrvMs: 60), baseline: baseline),
        100,
      );
      expect(
        readinessScore(signals: const RecoverySignals(hrvMs: 40), baseline: baseline),
        0,
      );
    });

    test('HRV with no baseline to compare against is ignored', () {
      expect(readinessScore(signals: const RecoverySignals(hrvMs: 60)), isNull);
    });

    test('a raised resting heart rate lowers readiness', () {
      const baseline = RecoveryBaseline(restingHr: 50);
      final normal =
          readinessScore(signals: const RecoverySignals(restingHr: 50), baseline: baseline)!;
      final raised =
          readinessScore(signals: const RecoverySignals(restingHr: 55), baseline: baseline)!;
      expect(normal, 50);
      expect(raised, 0);
    });

    test('what the lifter says still moves a watch-measured score', () {
      const signals = RecoverySignals(sleepMinutes: 480, hrvMs: 60, restingHr: 50);
      const baseline = RecoveryBaseline(hrvMs: 60, restingHr: 50);
      final flat = readinessScore(
        checkIn: const CheckIn(energy: 3, soreness: 3, stress: 3, sleepQuality: 3),
        signals: signals,
        baseline: baseline,
      )!;
      final wrecked = readinessScore(
        checkIn: const CheckIn(energy: 1, soreness: 5, stress: 5, sleepQuality: 1),
        signals: signals,
        baseline: baseline,
      )!;
      expect(wrecked, lessThan(flat));
      expect(flat - wrecked, greaterThan(20));
    });

    test('stays inside 0-100 however extreme the inputs', () {
      final score = readinessScore(
        signals: const RecoverySignals(hrvMs: 500, restingHr: 20, sleepMinutes: 900),
        baseline: const RecoveryBaseline(hrvMs: 40, restingHr: 60),
      )!;
      expect(score, inInclusiveRange(0, 100));
      expect(score, 100);
    });

    test('rejects negative sleep', () {
      expect(
        () => readinessScore(signals: const RecoverySignals(sleepMinutes: -1)),
        throwsArgumentError,
      );
    });
  });

  group('recoveryBaseline', () {
    test('is empty when there are no nights to average', () {
      final baseline = recoveryBaseline([]);
      expect(baseline.hrvMs, isNull);
      expect(baseline.restingHr, isNull);
      expect(baseline.sleepMinutesTarget, 480);
    });

    test('takes the median so one outlier does not move it', () {
      final baseline = recoveryBaseline(const [
        RecoverySignals(hrvMs: 50),
        RecoverySignals(hrvMs: 52),
        RecoverySignals(hrvMs: 48),
        RecoverySignals(hrvMs: 200), // watch left on the nightstand
      ]);
      expect(baseline.hrvMs, 51);
    });

    test('skips nights where the signal is missing', () {
      final baseline = recoveryBaseline(const [
        RecoverySignals(hrvMs: 40),
        RecoverySignals(restingHr: 55),
        RecoverySignals(hrvMs: 60),
      ]);
      expect(baseline.hrvMs, 50);
      expect(baseline.restingHr, 55);
    });

    test('carries a custom sleep target through', () {
      expect(recoveryBaseline([], sleepMinutesTarget: 420).sleepMinutesTarget, 420);
    });
  });

  group('sleptShort', () {
    test('is the spec six-hour line', () {
      expect(sleptShort(const RecoverySignals(sleepMinutes: 359)), isTrue);
      expect(sleptShort(const RecoverySignals(sleepMinutes: 360)), isFalse);
    });

    test('is false when the night was not measured', () {
      expect(sleptShort(const RecoverySignals()), isFalse);
    });
  });
}

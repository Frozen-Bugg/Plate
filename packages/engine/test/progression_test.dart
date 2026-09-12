import 'package:engine/engine.dart';
import 'package:test/test.dart';

void main() {
  group('DoubleProgression', () {
    // 8-12 reps, 2.5 kg dumbbell step, sets meant to leave 2 in reserve.
    const model = DoubleProgression(
      repMin: 8,
      repMax: 12,
      loadStepKg: 2.5,
      targetRir: 2,
    );

    test('with no history it asks for the bottom of the range', () {
      final next = model.next();
      expect(next.reps, 8);
      expect(next.reason, ProgressionReason.firstExposure);
    });

    test('top of the range on every set at target effort adds a step', () {
      final next = model.next(
        last: const Exposure(sets: [
          SetLog(weightKg: 30, reps: 12, rir: 2),
          SetLog(weightKg: 30, reps: 12, rir: 2),
          SetLog(weightKg: 30, reps: 12, rir: 2),
        ]),
      );
      expect(next.loadKg, 32.5);
      expect(next.reps, 8, reason: 'resets to the bottom of the range');
      expect(next.reason, ProgressionReason.loadIncreased);
    });

    // The effort gate: the load must not climb off a grinding session.
    test('top of the range but over target effort does not add load', () {
      final next = model.next(
        last: const Exposure(sets: [
          SetLog(weightKg: 30, reps: 12, rir: 2),
          SetLog(weightKg: 30, reps: 12, rir: 0), // ground out
          SetLog(weightKg: 30, reps: 12, rir: 2),
        ]),
      );
      expect(next.loadKg, 30);
      expect(next.reason, ProgressionReason.held);
    });

    test('one set short of the top holds the load and chases reps', () {
      final next = model.next(
        last: const Exposure(sets: [
          SetLog(weightKg: 30, reps: 12, rir: 2),
          SetLog(weightKg: 30, reps: 10, rir: 2),
          SetLog(weightKg: 30, reps: 12, rir: 2),
        ]),
      );
      expect(next.loadKg, 30);
      expect(next.reps, 11, reason: 'one more than the weakest set');
      expect(next.reason, ProgressionReason.repsIncreased);
    });

    test('never asks for more than the top of the range', () {
      final next = model.next(
        last: const Exposure(sets: [
          SetLog(weightKg: 30, reps: 12, rir: 2),
          SetLog(weightKg: 30, reps: 14, rir: 2), // overshot
        ]),
      );
      expect(next.reps, lessThanOrEqualTo(12));
    });

    test('never asks for fewer than the bottom of the range', () {
      final next = model.next(
        last: const Exposure(sets: [SetLog(weightKg: 30, reps: 4, rir: 0)]),
      );
      expect(next.reps, 8);
    });

    test('unrated sets do not block a well-earned increase', () {
      final next = model.next(
        last: const Exposure(sets: [
          SetLog(weightKg: 30, reps: 12),
          SetLog(weightKg: 30, reps: 12),
        ]),
      );
      expect(next.loadKg, 32.5);
      expect(next.reason, ProgressionReason.loadIncreased);
    });

    test('with no effort target the rep range alone decides', () {
      const noEffortGate =
          DoubleProgression(repMin: 8, repMax: 12, loadStepKg: 2.5);
      final next = noEffortGate.next(
        last: const Exposure(sets: [
          SetLog(weightKg: 30, reps: 12, rir: 0), // would fail the gate
          SetLog(weightKg: 30, reps: 12, rir: 0),
        ]),
      );
      expect(next.loadKg, 32.5);
    });

    test('a heavier machine step is respected', () {
      const machine =
          DoubleProgression(repMin: 8, repMax: 12, loadStepKg: 5, targetRir: 2);
      final next = machine.next(
        last: const Exposure(sets: [SetLog(weightKg: 50, reps: 12, rir: 2)]),
      );
      expect(next.loadKg, 55);
    });
  });

  group('LinearProgression', () {
    // 5 kg a session is the spec's lower-body increment.
    const squat = LinearProgression(incrementKg: 5, reps: 5);

    test('hitting the prescription adds the increment', () {
      final next = squat.next(
        last: const Exposure(sets: [
          SetLog(weightKg: 100, reps: 5),
          SetLog(weightKg: 100, reps: 5),
          SetLog(weightKg: 100, reps: 5),
        ]),
      );
      expect(next.loadKg, 105);
      expect(next.reps, 5);
      expect(next.reason, ProgressionReason.loadIncreased);
    });

    test('the upper-body increment is the caller\'s to set', () {
      const bench = LinearProgression(incrementKg: 2.5, reps: 5);
      final next = bench.next(
        last: const Exposure(sets: [SetLog(weightKg: 80, reps: 5)]),
      );
      expect(next.loadKg, 82.5);
    });

    test('a first miss repeats the same load', () {
      final next = squat.next(
        last: const Exposure(sets: [
          SetLog(weightKg: 100, reps: 5),
          SetLog(weightKg: 100, reps: 3), // missed
        ]),
      );
      expect(next.loadKg, 100);
      expect(next.reason, ProgressionReason.held);
    });

    test('a second miss strips 10%', () {
      final next = squat.next(
        last: const Exposure(sets: [SetLog(weightKg: 100, reps: 3)]),
        consecutiveFailures: 1,
      );
      expect(next.loadKg, closeTo(90, 0.001));
      expect(next.reason, ProgressionReason.deloaded);
    });

    test('with no history it asks for the prescribed reps', () {
      expect(squat.next().reason, ProgressionReason.firstExposure);
      expect(squat.next().reps, 5);
    });
  });

  group('ProgressionModel', () {
    test('maps to and from the value stored in the database', () {
      expect(ProgressionModel.fromWire('double'), ProgressionModel.double_);
      expect(ProgressionModel.fromWire('linear'), ProgressionModel.linear);
      expect(ProgressionModel.double_.wireName, 'double');
    });

    test('an unknown model is an error, not a silent default', () {
      expect(() => ProgressionModel.fromWire('nonsense'), throwsArgumentError);
    });
  });
}

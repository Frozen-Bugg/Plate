import 'package:engine/engine.dart';
import 'package:test/test.dart';

/// One exposure at a fixed load and effort, to keep the tests about the rule
/// rather than about arithmetic.
Exposure at({required double kg, required int reps, double? rir}) =>
    Exposure(sets: [SetLog(weightKg: kg, reps: reps, rir: rir)]);

void main() {
  group('isStalled', () {
    test('needs three exposures before it will judge', () {
      expect(isStalled([at(kg: 100, reps: 5, rir: 1)]), isFalse);
      expect(
        isStalled([
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 100, reps: 5, rir: 1),
        ]),
        isFalse,
      );
    });

    test('three flat exposures at the same effort is a stall', () {
      expect(
        isStalled([
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 100, reps: 5, rir: 1),
        ]),
        isTrue,
      );
    });

    test('flat but getting harder is still a stall', () {
      expect(
        isStalled([
          at(kg: 100, reps: 5, rir: 3),
          at(kg: 100, reps: 5, rir: 2),
          at(kg: 100, reps: 5, rir: 1),
        ]),
        isTrue,
      );
    });

    // The half of the rule that is easy to forget: flat work that is getting
    // easier is a lifter holding back, and deloading them would be wrong.
    test('flat but getting easier is not a stall', () {
      expect(
        isStalled([
          at(kg: 100, reps: 5, rir: 0),
          at(kg: 100, reps: 5, rir: 2),
          at(kg: 100, reps: 5, rir: 3),
        ]),
        isFalse,
      );
    });

    test('any gain in the window clears it', () {
      expect(
        isStalled([
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 105, reps: 5, rir: 1),
        ]),
        isFalse,
      );
    });

    test('judges the recent run against the best before it', () {
      // A good session, then three that never match it again.
      expect(
        isStalled([
          at(kg: 120, reps: 5, rir: 1),
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 100, reps: 5, rir: 1),
        ]),
        isTrue,
      );
    });

    test('beating an older best clears it', () {
      expect(
        isStalled([
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 125, reps: 5, rir: 1),
        ]),
        isFalse,
      );
    });

    test('unrated exposures stall on the e1RM alone', () {
      expect(
        isStalled([
          at(kg: 100, reps: 5),
          at(kg: 100, reps: 5),
          at(kg: 100, reps: 5),
        ]),
        isTrue,
      );
    });

    test('more reps at the same load counts as a gain', () {
      expect(
        isStalled([
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 100, reps: 5, rir: 1),
          at(kg: 100, reps: 6, rir: 1),
        ]),
        isFalse,
      );
    });

    test('the window is adjustable', () {
      final flat = [
        at(kg: 100, reps: 5, rir: 1),
        at(kg: 100, reps: 5, rir: 1),
      ];
      expect(isStalled(flat, window: 2), isTrue);
      expect(isStalled(flat, window: 3), isFalse);
    });

    test('rejects a nonsense window', () {
      expect(() => isStalled(const [], window: 0), throwsArgumentError);
    });
  });

  group('stallCount', () {
    test('is zero with no history', () {
      expect(stallCount(const []), 0);
    });

    test('counts exposures since the last personal best', () {
      expect(
        stallCount([
          at(kg: 100, reps: 5),
          at(kg: 100, reps: 5),
          at(kg: 100, reps: 5),
        ]),
        2,
      );
    });

    test('resets when the lifter beats their best', () {
      expect(
        stallCount([
          at(kg: 100, reps: 5),
          at(kg: 100, reps: 5),
          at(kg: 105, reps: 5),
        ]),
        0,
      );
    });

    test('keeps counting after a failed attempt to beat the best', () {
      expect(
        stallCount([
          at(kg: 105, reps: 5),
          at(kg: 100, reps: 5),
          at(kg: 100, reps: 5),
        ]),
        2,
      );
    });
  });
}

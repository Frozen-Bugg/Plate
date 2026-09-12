import 'package:engine/engine.dart';
import 'package:test/test.dart';

void main() {
  group('e1rm', () {
    test('a single rep is the load itself', () {
      expect(e1rm(loadKg: 100, reps: 1), closeTo(103.333, 0.001));
    });

    test('follows Epley: load x (1 + reps / 30)', () {
      // 100 x 10 -> 100 * (1 + 10/30) = 133.33
      expect(e1rm(loadKg: 100, reps: 10), closeTo(133.333, 0.001));
      // 60 x 5 -> 60 * (1 + 5/30) = 70
      expect(e1rm(loadKg: 60, reps: 5), closeTo(70, 0.001));
    });

    test('more reps at the same load estimates a higher max', () {
      expect(
        e1rm(loadKg: 80, reps: 8),
        greaterThan(e1rm(loadKg: 80, reps: 6)),
      );
    });

    test('rejects impossible input', () {
      expect(() => e1rm(loadKg: 100, reps: 0), throwsArgumentError);
      expect(() => e1rm(loadKg: -1, reps: 5), throwsArgumentError);
    });
  });

  group('e1rmWithRir', () {
    test('counts reps left in reserve', () {
      // 100 x 8 with 2 left == 100 x 10 to failure
      expect(
        e1rmWithRir(loadKg: 100, reps: 8, rir: 2),
        closeTo(e1rm(loadKg: 100, reps: 10), 0.001),
      );
    });

    test('with nothing left in reserve it matches plain Epley', () {
      expect(
        e1rmWithRir(loadKg: 90, reps: 6, rir: 0),
        closeTo(e1rm(loadKg: 90, reps: 6), 0.001),
      );
    });

    test('rejects negative reserve', () {
      expect(
        () => e1rmWithRir(loadKg: 100, reps: 5, rir: -1),
        throwsArgumentError,
      );
    });
  });

  group('rpe and rir', () {
    test('RPE 8 is two reps in reserve', () {
      expect(rpeToRir(8), 2);
      expect(rirToRpe(2), 8);
    });

    test('RPE 10 is nothing left', () {
      expect(rpeToRir(10), 0);
    });
  });

  group('SetLog', () {
    test('uses the RIR-aware estimate when the set was rated', () {
      const rated = SetLog(weightKg: 100, reps: 8, rir: 2);
      expect(rated.estimatedOneRepMax, closeTo(133.333, 0.001));
      expect(rated.rpe, 8);
    });

    test('falls back to plain Epley when it was not', () {
      const unrated = SetLog(weightKg: 100, reps: 8);
      expect(unrated.estimatedOneRepMax, closeTo(126.666, 0.001));
      expect(unrated.rpe, isNull);
    });
  });

  group('Exposure', () {
    test('reports the best set, not the last', () {
      const exposure = Exposure(sets: [
        SetLog(weightKg: 100, reps: 8),
        SetLog(weightKg: 100, reps: 10),
        SetLog(weightKg: 100, reps: 6),
      ]);
      expect(exposure.bestE1rm, closeTo(e1rm(loadKg: 100, reps: 10), 0.001));
    });

    test('prescribed load defaults to the heaviest set', () {
      const exposure = Exposure(sets: [
        SetLog(weightKg: 60, reps: 10),
        SetLog(weightKg: 80, reps: 8),
      ]);
      expect(exposure.prescribedLoadKg, 80);
    });

    test('hardest effort is the highest RPE, ignoring unrated sets', () {
      const exposure = Exposure(sets: [
        SetLog(weightKg: 100, reps: 8, rir: 3),
        SetLog(weightKg: 100, reps: 8),
        SetLog(weightKg: 100, reps: 8, rir: 1),
      ]);
      expect(exposure.hardestRpe, 9);
    });

    test('hardest effort is null when nothing was rated', () {
      const exposure = Exposure(sets: [SetLog(weightKg: 100, reps: 8)]);
      expect(exposure.hardestRpe, isNull);
    });
  });
}

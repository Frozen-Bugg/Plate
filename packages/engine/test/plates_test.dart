import 'package:engine/engine.dart';
import 'package:test/test.dart';

void main() {
  group('platesFor', () {
    test('loads a round number off a 20 kg bar', () {
      final load = platesFor(targetKg: 100);
      expect(load.perSide, [25, 15]);
      expect(load.totalKg, 100);
      expect(load.isExact, isTrue);
    });

    test('reaches the plate-sized increments the engine actually asks for', () {
      // 62.5 is what double progression produces from 60 with a 2.5 step.
      final load = platesFor(targetKg: 62.5);
      expect(load.perSide, [20, 1.25]);
      expect(load.totalKg, 62.5);
    });

    test('an empty bar needs no plates', () {
      final load = platesFor(targetKg: 20);
      expect(load.perSide, isEmpty);
      expect(load.totalKg, 20);
      expect(load.isExact, isTrue);
    });

    test('uses the heaviest plates first, so the bar is not a necklace', () {
      expect(platesFor(targetKg: 140).perSide, [25, 25, 10]);
    });

    // Gyms have finite plates. Saying "61 kg" when the bar cannot make it is
    // worse than saying what it can.
    test('reports the shortfall when the plates cannot get there', () {
      final load = platesFor(targetKg: 61);
      expect(load.totalKg, 60);
      expect(load.shortfallKg, 1);
      expect(load.isExact, isFalse);
    });

    test('below the bar there is nothing to load', () {
      final load = platesFor(targetKg: 15);
      expect(load.perSide, isEmpty);
      expect(load.belowBar, isTrue);
    });

    test('respects a different bar', () {
      // A 15 kg women's bar.
      final load = platesFor(targetKg: 55, barKg: 15);
      expect(load.perSide, [20]);
      expect(load.totalKg, 55);
    });

    test('respects a limited plate set', () {
      final load = platesFor(targetKg: 100, availableKg: const [20, 10]);
      expect(load.perSide, [20, 20]);
      expect(load.totalKg, 100);
    });

    test('a gym with only big plates cannot make small jumps', () {
      final load = platesFor(targetKg: 65, availableKg: const [20]);
      expect(load.totalKg, 60);
      expect(load.shortfallKg, 5);
    });

    test('floating point does not eat a plate', () {
      // 0.1 + 0.2 arithmetic shows up in loads derived from percentages.
      final load = platesFor(targetKg: 20 + 2 * (1.25 + 2.5));
      expect(load.perSide, [2.5, 1.25]);
      expect(load.isExact, isTrue);
    });

    test('rejects a negative bar', () {
      expect(() => platesFor(targetKg: 100, barKg: -1), throwsArgumentError);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:overload/features/train/rest_timer.dart';

void main() {
  final start = DateTime(2026, 9, 12, 14, 0);

  RestTimerState resting(Duration total) => RestTimerState(
        endsAt: start.add(total),
        total: total,
        exerciseId: 'e-1',
      );

  group('remaining', () {
    test('is the full rest at the moment it starts', () {
      expect(
        resting(const Duration(minutes: 2)).remaining(start),
        const Duration(minutes: 2),
      );
    });

    test('counts down with the wall clock', () {
      final state = resting(const Duration(minutes: 2));
      expect(
        state.remaining(start.add(const Duration(seconds: 30))),
        const Duration(seconds: 90),
      );
    });

    // The reason this holds an end time rather than a ticking counter: the
    // screen sleeps mid-set, and the clock has to still be right.
    test('is correct after a gap with no ticks at all', () {
      final state = resting(const Duration(minutes: 2));
      expect(
        state.remaining(start.add(const Duration(seconds: 119))),
        const Duration(seconds: 1),
      );
    });

    test('never goes negative once the rest is over', () {
      final state = resting(const Duration(minutes: 2));
      expect(
        state.remaining(start.add(const Duration(minutes: 10))),
        Duration.zero,
      );
    });

    test('is zero when nothing is running', () {
      expect(const RestTimerState().remaining(start), Duration.zero);
      expect(const RestTimerState().isRunning, isFalse);
    });
  });

  group('progress', () {
    test('runs from 0 at the start to 1 at the end', () {
      final state = resting(const Duration(minutes: 2));
      expect(state.progress(start), 0);
      expect(state.progress(start.add(const Duration(minutes: 1))), 0.5);
      expect(state.progress(start.add(const Duration(minutes: 2))), 1);
    });

    test('clamps rather than overshooting once the rest is over', () {
      final state = resting(const Duration(minutes: 2));
      expect(state.progress(start.add(const Duration(minutes: 5))), 1);
    });

    test('is complete when nothing is running, so no bar is drawn', () {
      expect(const RestTimerState().progress(start), 1);
    });
  });
}

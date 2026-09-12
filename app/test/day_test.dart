import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/day.dart';

void main() {
  group('dayKey', () {
    test('is the ISO date Postgres stores', () {
      expect(dayKey(DateTime(2026, 9, 12)), '2026-09-12');
    });

    test('pads a single-digit month and day', () {
      expect(dayKey(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('reads the local calendar, not the UTC one', () {
      // Late evening local is already tomorrow in UTC east of Greenwich, and
      // still yesterday west of it. The weigh-in belongs to the day the lifter
      // was standing on the scale either way.
      final evening = DateTime(2026, 9, 12, 23, 30);
      expect(dayKey(evening), '2026-09-12');
      expect(dayKey(evening.toUtc()), '2026-09-12');
    });

    test('sorts lexicographically, which is how the queries range over it', () {
      final days = [
        dayKey(DateTime(2026, 9, 12)),
        dayKey(DateTime(2026, 10, 1)),
        dayKey(DateTime(2026, 1, 31)),
      ]..sort();
      expect(days, ['2026-01-31', '2026-09-12', '2026-10-01']);
    });
  });

  group('parseDayKey', () {
    test('round-trips a key', () {
      expect(dayKey(parseDayKey('2026-09-12')), '2026-09-12');
    });

    test('returns a UTC midnight, so day arithmetic cannot lose an hour', () {
      final parsed = parseDayKey('2026-03-29');
      expect(parsed.isUtc, isTrue);
      expect(parsed.hour, 0);
      // The clocks go forward on this date in much of Europe; a local DateTime
      // would make the gap 23 hours and the engine would see no day at all.
      expect(parseDayKey('2026-03-30').difference(parsed).inDays, 1);
    });

    test('rejects something that is not a day', () {
      expect(() => parseDayKey('yesterday'), throwsFormatException);
      expect(() => parseDayKey('2026-09'), throwsFormatException);
    });
  });

  group('daysAgo', () {
    test('counts back from today', () {
      expect(daysAgo(0), dayKey());
      expect(
        daysAgo(1),
        dayKey(DateTime.now().subtract(const Duration(days: 1))),
      );
    });
  });
}

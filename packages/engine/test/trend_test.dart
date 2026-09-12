import 'package:engine/engine.dart';
import 'package:test/test.dart';

DateTime day(int n) => DateTime.utc(2026, 9, n);

List<WeighIn> daily(List<double> kg, {int from = 1}) => [
      for (var i = 0; i < kg.length; i++)
        WeighIn(date: day(from + i), weightKg: kg[i]),
    ];

void main() {
  group('weightTrend', () {
    test('is empty with nothing to smooth', () {
      expect(weightTrend([]), isEmpty);
    });

    test('starts at the first reading', () {
      final trend = weightTrend(daily([80]));
      expect(trend.single.trendKg, 80);
      expect(trend.single.weightKg, 80);
    });

    test('follows the spec formula day by day', () {
      // 80, then 82: 80 + 0.1 * (82 - 80) = 80.2
      final trend = weightTrend(daily([80, 82]));
      expect(trend[1].trendKg, closeTo(80.2, 1e-9));
    });

    test('barely moves for a single day of water weight', () {
      final trend = weightTrend(daily([80, 80, 80, 83]));
      // A 3 kg overnight jump shows up as 300 g on the line.
      expect(trend.last.trendKg, closeTo(80.3, 1e-9));
      expect(trend.last.weightKg, 83);
    });

    test('catches up to a real change within a couple of weeks', () {
      final trend = weightTrend(daily(List.filled(14, 78), from: 1)
        ..insert(0, WeighIn(date: DateTime.utc(2026, 8, 31), weightKg: 80)));
      expect(trend.last.trendKg, lessThan(78.6));
      expect(trend.last.trendKg, greaterThan(78));
    });

    test('averages several readings on the same day', () {
      final trend = weightTrend([
        WeighIn(date: day(1), weightKg: 80),
        WeighIn(date: day(1), weightKg: 82),
      ]);
      expect(trend.single.weightKg, 81);
      expect(trend.single.trendKg, 81);
    });

    test('does not care what order the weigh-ins arrive in', () {
      final ordered = weightTrend(daily([80, 82, 81]));
      final shuffled = weightTrend([
        WeighIn(date: day(3), weightKg: 81),
        WeighIn(date: day(1), weightKg: 80),
        WeighIn(date: day(2), weightKg: 82),
      ]);
      expect(shuffled.map((p) => p.trendKg), ordered.map((p) => p.trendKg));
    });

    test('a gap counts the days missed, not the readings missed', () {
      // Weighing weekly should move the line as far as seven daily readings of
      // the same weight would have.
      final weekly = weightTrend([
        WeighIn(date: day(1), weightKg: 80),
        WeighIn(date: day(8), weightKg: 82),
      ]);
      final everyDay = weightTrend(daily([80, 82, 82, 82, 82, 82, 82, 82]));
      expect(weekly.last.trendKg, closeTo(everyDay.last.trendKg, 1e-9));
    });

    test('honours a different smoothing constant', () {
      final trend = weightTrend(daily([80, 90]), smoothing: 0.5);
      expect(trend.last.trendKg, closeTo(85, 1e-9));
    });

    test('rejects a smoothing constant outside (0, 1]', () {
      expect(() => weightTrend(daily([80]), smoothing: 0), throwsArgumentError);
      expect(() => weightTrend(daily([80]), smoothing: 1.5), throwsArgumentError);
    });

    test('treats a timestamp as the day it falls on', () {
      final trend = weightTrend([
        WeighIn(date: DateTime.utc(2026, 9, 1, 6, 30), weightKg: 80),
        WeighIn(date: DateTime.utc(2026, 9, 1, 21, 15), weightKg: 82),
      ]);
      expect(trend, hasLength(1));
      expect(trend.single.weightKg, 81);
    });
  });

  group('weeklyRateKg', () {
    test('is null with nothing to compare', () {
      expect(weeklyRateKg([]), isNull);
      expect(weeklyRateKg(weightTrend(daily([80]))), isNull);
    });

    test('is null until the window is wide enough to fit a line to', () {
      expect(weeklyRateKg(weightTrend(daily([80, 80, 80]))), isNull);
      // Ten days of span is the floor, and five readings inside it.
      expect(weeklyRateKg(weightTrend(daily(List.filled(11, 80)))), isNotNull);
      expect(
        weeklyRateKg(weightTrend([
          WeighIn(date: day(1), weightKg: 80),
          WeighIn(date: day(2), weightKg: 80),
          WeighIn(date: day(11), weightKg: 80),
        ])),
        isNull,
      );
    });

    test('reports a steady loss per week', () {
      final trend = weightTrend(
        daily([for (var i = 0; i < 15; i++) 80 - i * 0.1]),
      );
      expect(weeklyRateKg(trend), closeTo(-0.7, 1e-9));
    });

    test('is not fooled by the lag that makes the trend line late', () {
      // The whole reason the rate is fitted rather than differenced: two weeks
      // in, the trend line has only travelled about half the real distance.
      final trend = weightTrend(
        daily([for (var i = 0; i < 15; i++) 80 - i * 0.1]),
      );
      final differenced =
          (trend.last.trendKg - trend.first.trendKg) / 14 * 7;
      expect(differenced, greaterThan(-0.45));
      expect(weeklyRateKg(trend), closeTo(-0.7, 1e-9));
    });

    test('one heavy day does not become a trend', () {
      // Flat for a fortnight, then a 3 kg Sunday. Read end to end that is
      // +1.5 kg/week; fitted, it is a fraction of that.
      final readings = daily(List.filled(15, 80))
        ..[14] = WeighIn(date: day(15), weightKg: 83);
      final rate = weeklyRateKg(weightTrend(readings))!;
      expect(rate, greaterThan(0));
      expect(rate, lessThan(0.75));
    });

    test('ignores readings older than the window', () {
      // Half a kilo a day for a fortnight, then flat for a fortnight.
      final readings = [
        for (var i = 0; i < 30; i++)
          WeighIn(date: day(i + 1), weightKg: 80 - (i < 15 ? i : 15) * 0.5),
      ];
      expect(weeklyRateKg(weightTrend(readings)), closeTo(0, 1e-9));
    });

    test('works for someone who weighs three times a week', () {
      final readings = [
        for (var i = 0; i < 21; i += 2)
          WeighIn(date: day(i + 1), weightKg: 80 - i * 0.1),
      ];
      expect(weeklyRateKg(weightTrend(readings)), closeTo(-0.7, 1e-9));
    });
  });

  group('weeklyRatePercent', () {
    test('expresses the rate as a share of bodyweight', () {
      final trend = weightTrend(
        daily([for (var i = 0; i < 15; i++) 100 - i * 0.1]),
      );
      final kg = weeklyRateKg(trend)!;
      expect(weeklyRatePercent(trend),
          closeTo(kg / trend.last.trendKg * 100, 1e-9));
    });

    test('is null when the rate is', () {
      expect(weeklyRatePercent(weightTrend(daily([80]))), isNull);
    });
  });
  group('WeightPhase', () {
    test('round-trips the value stored in profiles.phase', () {
      for (final phase in WeightPhase.values) {
        expect(WeightPhase.fromWire(phase.wireName), phase);
      }
    });

    test('rejects an unknown phase', () {
      expect(() => WeightPhase.fromWire('recomp'), throwsArgumentError);
    });

    test('carries the spec bands', () {
      expect(WeightPhase.cut.minPercentPerWeek, -1.0);
      expect(WeightPhase.cut.maxPercentPerWeek, -0.5);
      expect(WeightPhase.bulk.maxPercentPerWeek, 0.5);
    });
  });

  group('judgeTrend', () {
    List<TrendPoint> at(double percentPerWeek, {double start = 100}) {
      // Daily readings walking at the requested weekly rate.
      final perDay = start * percentPerWeek / 100 / 7;
      return weightTrend(daily([for (var i = 0; i < 40; i++) start + i * perDay]));
    }

    test('says nothing without enough weigh-ins', () {
      expect(judgeTrend(weightTrend(daily([80, 80])), WeightPhase.cut),
          TrendVerdict.unknown);
    });

    test('a cut losing 0.75%/week is on target', () {
      expect(judgeTrend(at(-0.75), WeightPhase.cut), TrendVerdict.onTarget);
    });

    test('a cut that is not moving is above the band', () {
      expect(judgeTrend(at(0), WeightPhase.cut), TrendVerdict.above);
    });

    test('a cut shedding 1.5%/week is below it', () {
      expect(judgeTrend(at(-1.5), WeightPhase.cut), TrendVerdict.below);
    });

    test('maintenance tolerates drift in both directions', () {
      expect(judgeTrend(at(0.1), WeightPhase.maintain), TrendVerdict.onTarget);
      expect(judgeTrend(at(-0.1), WeightPhase.maintain), TrendVerdict.onTarget);
      expect(judgeTrend(at(0.6), WeightPhase.maintain), TrendVerdict.above);
      expect(judgeTrend(at(-0.6), WeightPhase.maintain), TrendVerdict.below);
    });

    test('a bulk gaining 0.4%/week is on target', () {
      expect(judgeTrend(at(0.4), WeightPhase.bulk), TrendVerdict.onTarget);
    });

    test('a bulk stuck flat is below the band', () {
      expect(judgeTrend(at(0), WeightPhase.bulk), TrendVerdict.below);
    });
  });
}

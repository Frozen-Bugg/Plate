import 'dart:math' as math;

/// One reading off the scale.
///
/// [date] is the calendar day it was taken, not a timestamp: two weigh-ins on
/// the same morning are the same day's data, however far apart the clock says
/// they were.
class WeighIn {
  const WeighIn({required this.date, required this.weightKg});

  final DateTime date;
  final double weightKg;

  @override
  String toString() => 'WeighIn(${_ymd(date)}, ${weightKg}kg)';
}

/// A day's scale reading beside the smoothed value the engine derived from it.
class TrendPoint {
  const TrendPoint({
    required this.date,
    required this.weightKg,
    required this.trendKg,
  });

  final DateTime date;

  /// What the scale said that day, averaged if it was stepped on more than once.
  final double weightKg;

  /// The smoothed line — the number worth reacting to.
  final double trendKg;

  @override
  String toString() =>
      'TrendPoint(${_ymd(date)}, scale ${weightKg}kg, trend ${trendKg}kg)';
}

/// Smoothed bodyweight, the headline number in the Body pillar.
///
/// From the spec (docs/PLAN.md §6):
///
/// ```
/// trend[t] = trend[t-1] + 0.1 x (scale[t] - trend[t-1])
/// ```
///
/// Day-to-day scale weight is mostly water, gut content and salt; the trend is
/// the part that reflects tissue. [smoothing] of 0.1 means a single day moves
/// the line by a tenth of its distance from the scale, so a 1 kg overnight
/// jump shows up as 100 g and a real change still arrives inside a week.
///
/// **Gaps.** The spec's formula assumes a reading every day. Applied once per
/// *observation* it would mean a lifter who weighs weekly gets a trend that
/// barely moves, which is wrong — five days of not weighing is missing
/// evidence, not evidence of stability. So the smoothing compounds over the
/// days actually elapsed: a gap of `n` days pulls the trend as if the same
/// reading had been seen each of those days. With daily weigh-ins this is
/// exactly the formula above.
///
/// [weighIns] may be in any order and may contain several readings for one
/// day; the result is one point per day that has data, oldest first. The trend
/// starts at the first reading rather than at zero, so it is usable on day one
/// — but it carries that day's water weight until a few more arrive.
List<TrendPoint> weightTrend(
  List<WeighIn> weighIns, {
  double smoothing = 0.1,
}) {
  if (smoothing <= 0 || smoothing > 1) {
    throw ArgumentError.value(smoothing, 'smoothing', 'must be in (0, 1]');
  }
  if (weighIns.isEmpty) return const [];

  // Average same-day readings: stepping on twice is not two days of evidence.
  final byDay = <DateTime, List<double>>{};
  for (final w in weighIns) {
    (byDay[_dayOf(w.date)] ??= []).add(w.weightKg);
  }
  final days = byDay.keys.toList()..sort();

  final points = <TrendPoint>[];
  late double trend;
  late DateTime previous;

  for (final day in days) {
    final readings = byDay[day]!;
    final scale = readings.reduce((a, b) => a + b) / readings.length;

    if (points.isEmpty) {
      trend = scale;
    } else {
      final gap = day.difference(previous).inDays;
      // 1 - (1 - a)^gap: the same pull applied once per elapsed day.
      final alpha = 1 - math.pow(1 - smoothing, gap).toDouble();
      trend += alpha * (scale - trend);
    }
    previous = day;
    points.add(TrendPoint(date: day, weightKg: scale, trendKg: trend));
  }
  return points;
}

/// How fast bodyweight is actually moving, in kg per week, over the last
/// [days].
///
/// Fitted by least squares to the **scale** readings in the window, not to the
/// smoothed line, and that is deliberate. The two answer different questions:
///
///   * The trend is the right *level* — it is what the lifter should read off
///     the screen, because it has the water weight taken out of it.
///   * The trend is the wrong *rate*. An exponential average lags its input by
///     about `1/smoothing` days, and that lag builds up over the first weeks of
///     a series, so the difference between two trend points under-reports real
///     change by roughly half at a fortnight and a quarter at a month. On a cut
///     that reads as "barely losing" — and the fix for barely losing is to eat
///     less, which is the dangerous direction to be wrong in.
///
/// A straight-line fit has no such lag: it is unbiased as soon as the window is
/// full. The price is noise — it is estimated from unsmoothed readings — so it
/// is a number to act on over weeks, not days. The spec's rule that a trend
/// must sit off target for a fortnight before anything is proposed
/// (docs/PLAN.md §6) is what absorbs that.
///
/// Returns null until the window holds at least five readings spanning ten days
/// or more. Below that the fit is a line through noise.
double? weeklyRateKg(List<TrendPoint> trend, {int days = 14}) {
  if (trend.length < 2) return null;

  final cutoff = trend.last.date.subtract(Duration(days: days - 1));
  final window = trend.where((p) => !p.date.isBefore(cutoff)).toList();
  if (window.length < 5) return null;
  if (trend.last.date.difference(window.first.date).inDays < 10) return null;

  final origin = window.first.date;
  final xs = [
    for (final p in window) p.date.difference(origin).inDays.toDouble(),
  ];
  final ys = [for (final p in window) p.weightKg];
  final meanX = xs.reduce((a, b) => a + b) / xs.length;
  final meanY = ys.reduce((a, b) => a + b) / ys.length;

  var covariance = 0.0;
  var variance = 0.0;
  for (var i = 0; i < xs.length; i++) {
    covariance += (xs[i] - meanX) * (ys[i] - meanY);
    variance += (xs[i] - meanX) * (xs[i] - meanX);
  }
  if (variance == 0) return null;

  return covariance / variance * 7;
}

/// The weekly rate as a percentage of current bodyweight — the units every
/// phase target in the spec is written in.
///
/// Measured against the trend rather than the last reading: dividing a rate by
/// a number that includes yesterday's salt would put the noise back in.
double? weeklyRatePercent(List<TrendPoint> trend, {int days = 14}) {
  final kg = weeklyRateKg(trend, days: days);
  if (kg == null) return null;
  final current = trend.last.trendKg;
  if (current <= 0) return null;
  return kg / current * 100;
}

/// Which way the lifter has told the app they want the scale to go.
enum WeightPhase {
  cut('cut', -1.0, -0.5),
  maintain('maintain', -0.25, 0.25),
  bulk('bulk', 0.25, 0.5);

  const WeightPhase(this.wireName, this.minPercentPerWeek, this.maxPercentPerWeek);

  /// The value stored in `profiles.phase`.
  final String wireName;

  /// The target band, as a percentage of bodyweight per week (docs/PLAN.md §6).
  final double minPercentPerWeek;
  final double maxPercentPerWeek;

  static WeightPhase fromWire(String value) => values.firstWhere(
        (p) => p.wireName == value,
        orElse: () => throw ArgumentError.value(value, 'value', 'unknown phase'),
      );
}

/// Whether the trend is doing what the phase asks of it.
enum TrendVerdict {
  /// Inside the phase's band.
  onTarget,

  /// Moving up faster than the phase wants — or, on a cut, not coming down.
  above,

  /// Moving down faster than the phase wants.
  below,

  /// Not enough weigh-ins yet to say.
  unknown,
}

/// Judges the trend against the phase's band.
///
/// Deliberately quiet when it cannot tell: [TrendVerdict.unknown] rather than a
/// guess, because this feeds a proposal to change someone's calories.
TrendVerdict judgeTrend(List<TrendPoint> trend, WeightPhase phase, {int days = 14}) {
  final rate = weeklyRatePercent(trend, days: days);
  if (rate == null) return TrendVerdict.unknown;
  // Floating point: a rate sitting exactly on the boundary is on target.
  const epsilon = 1e-9;
  if (rate > phase.maxPercentPerWeek + epsilon) return TrendVerdict.above;
  if (rate < phase.minPercentPerWeek - epsilon) return TrendVerdict.below;
  return TrendVerdict.onTarget;
}

DateTime _dayOf(DateTime d) => DateTime.utc(d.year, d.month, d.day);

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

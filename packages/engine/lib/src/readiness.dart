/// The morning check-in: four questions, ten seconds, all optional.
///
/// Every answer is the 1-5 the lifter tapped. Two of them run the other way —
/// 5 soreness and 5 stress are bad mornings, 5 sleep quality and 5 energy are
/// good ones — and the engine inverts them rather than asking the UI to, so
/// there is exactly one place to get the direction wrong.
class CheckIn {
  const CheckIn({
    this.sleepQuality,
    this.soreness,
    this.stress,
    this.energy,
  });

  /// How well they slept. 1 = badly, 5 = well.
  final int? sleepQuality;

  /// How sore they are. 1 = fresh, 5 = wrecked.
  final int? soreness;

  /// How stressed they are. 1 = calm, 5 = frayed.
  final int? stress;

  /// How much they have in the tank. 1 = empty, 5 = full.
  final int? energy;

  bool get isEmpty =>
      sleepQuality == null && soreness == null && stress == null && energy == null;
}

/// Last night, as the watch measured it. All optional: a lifter with no
/// wearable still gets a readiness score, just from fewer inputs.
class RecoverySignals {
  const RecoverySignals({this.sleepMinutes, this.hrvMs, this.restingHr});

  final int? sleepMinutes;

  /// Heart rate variability, milliseconds. Higher is better rested.
  final double? hrvMs;

  /// Resting heart rate, bpm. Lower is better rested.
  final double? restingHr;

  bool get isEmpty => sleepMinutes == null && hrvMs == null && restingHr == null;
}

/// What normal looks like for this lifter.
///
/// HRV and resting heart rate are only meaningful against a personal baseline:
/// 45 ms is a good night for one person and a bad one for another. Sleep is
/// judged against a target instead, because eight hours is eight hours.
class RecoveryBaseline {
  const RecoveryBaseline({
    this.hrvMs,
    this.restingHr,
    this.sleepMinutesTarget = 480,
  });

  final double? hrvMs;
  final double? restingHr;
  final int sleepMinutesTarget;
}

/// Builds a baseline from recent nights, using medians so one bad night — or
/// one night the watch spent on the nightstand — does not move it.
///
/// Returns null components where there is nothing to average.
RecoveryBaseline recoveryBaseline(
  List<RecoverySignals> recent, {
  int sleepMinutesTarget = 480,
}) {
  double? median(Iterable<double?> values) {
    final present = values.whereType<double>().toList()..sort();
    if (present.isEmpty) return null;
    final mid = present.length ~/ 2;
    return present.length.isOdd
        ? present[mid]
        : (present[mid - 1] + present[mid]) / 2;
  }

  return RecoveryBaseline(
    hrvMs: median(recent.map((r) => r.hrvMs)),
    restingHr: median(recent.map((r) => r.restingHr)),
    sleepMinutesTarget: sleepMinutesTarget,
  );
}

/// Readiness, 0-100. Null when there is nothing to score.
///
/// A blend of what the lifter says and what their body says, weighted so that
/// neither alone decides it. Missing inputs are dropped and the rest
/// re-weighted, so the score means the same thing on the day a watch arrives
/// as on the day before — it is just measured from more.
///
/// Returning null rather than 50 for an empty morning matters: 50 is a claim
/// about how someone feels, and the app has no business making it up. The UI
/// shows nothing instead.
///
/// This is a readiness score, not a diagnosis. It shades the day's targets
/// (docs/PLAN.md §6) and it never changes the plan on its own.
int? readinessScore({
  CheckIn checkIn = const CheckIn(),
  RecoverySignals signals = const RecoverySignals(),
  RecoveryBaseline baseline = const RecoveryBaseline(),
}) {
  var weighted = 0.0;
  var weight = 0.0;

  void add(double? score, double w) {
    if (score == null) return;
    weighted += score * w;
    weight += w;
  }

  // Subjective: half the score when everything is present. What a lifter
  // notices about their own morning is data, not decoration.
  add(_scale(checkIn.energy), 0.20);
  add(_scale(checkIn.sleepQuality), 0.15);
  add(_scale(checkIn.soreness, inverted: true), 0.15);
  add(_scale(checkIn.stress, inverted: true), 0.10);

  add(_sleepScore(signals.sleepMinutes, baseline.sleepMinutesTarget), 0.15);
  add(_hrvScore(signals.hrvMs, baseline.hrvMs), 0.15);
  add(_restingHrScore(signals.restingHr, baseline.restingHr), 0.10);

  if (weight == 0) return null;
  return (weighted / weight * 100).round().clamp(0, 100);
}

/// A 1-5 answer as 0..1. [inverted] for the questions where 5 is the bad end.
double? _scale(int? value, {bool inverted = false}) {
  if (value == null) return null;
  if (value < 1 || value > 5) {
    throw ArgumentError.value(value, 'value', 'check-in answers are 1-5');
  }
  final normalised = (value - 1) / 4;
  return inverted ? 1 - normalised : normalised;
}

/// Sleep against the target. Full marks at the target, nothing at five hours
/// below it, linear between. Oversleeping is not penalised — the engine has no
/// evidence that nine hours is worse than eight, and plenty that six is.
double? _sleepScore(int? minutes, int target) {
  if (minutes == null) return null;
  if (minutes < 0) {
    throw ArgumentError.value(minutes, 'sleepMinutes', 'must not be negative');
  }
  const floorBelowTarget = 300;
  if (minutes >= target) return 1;
  final deficit = target - minutes;
  return (1 - deficit / floorBelowTarget).clamp(0.0, 1.0);
}

/// HRV against personal baseline: 20% above scores full, 20% below scores
/// zero, baseline itself sits in the middle.
double? _hrvScore(double? hrv, double? baseline) {
  if (hrv == null || baseline == null || baseline <= 0) return null;
  return (0.5 + (hrv / baseline - 1) * 2.5).clamp(0.0, 1.0);
}

/// Resting heart rate against personal baseline, the same way round but
/// reversed — a raised resting heart rate is the classic sign of a body still
/// dealing with yesterday. The band is tighter because RHR varies less.
double? _restingHrScore(double? rhr, double? baseline) {
  if (rhr == null || baseline == null || baseline <= 0) return null;
  return (0.5 + (1 - rhr / baseline) * 5).clamp(0.0, 1.0);
}

/// Whether the night was short enough to change how the day is coached.
///
/// The spec's rule (docs/PLAN.md §6): under six hours, today's targets get
/// +1 RIR in the brief and the plan itself is left alone.
bool sleptShort(RecoverySignals signals, {int thresholdMinutes = 360}) {
  final minutes = signals.sleepMinutes;
  return minutes != null && minutes < thresholdMinutes;
}

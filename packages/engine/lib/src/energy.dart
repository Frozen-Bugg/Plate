import 'trend.dart';

/// Energy in a kilogram of body mass, used to convert weight change into the
/// calories that must have caused it.
///
/// 7700 kcal/kg is the classic figure and the one the spec names. It is an
/// approximation — real tissue change is a mix of fat, glycogen and water, and
/// the water moves fastest — which is exactly why [observedTdee] is fed a
/// smoothed rate rather than two scale readings.
const kcalPerKg = 7700.0;

/// Biological sex, as Mifflin-St Jeor needs it.
///
/// The equation was fitted with a single binary term and no better-validated
/// alternative exists, so this is a modelling input rather than a statement
/// about anybody. It only ever shifts the estimate by 166 kcal, and the
/// adaptive loop below corrects whatever it gets wrong within a fortnight.
enum Sex {
  male('male'),
  female('female');

  const Sex(this.wireName);

  /// The value stored in `profiles.sex`.
  final String wireName;

  static Sex? fromWire(String? value) =>
      value == null ? null : values.where((s) => s.wireName == value).firstOrNull;
}

/// Resting burn by Mifflin-St Jeor, kcal/day.
///
/// The most accurate of the simple equations for people who are not very lean
/// or very heavy, and the one that underpins the seed estimate until real logs
/// take over.
double basalMetabolicRate({
  required double weightKg,
  required double heightCm,
  required int ageYears,
  required Sex sex,
}) {
  if (weightKg <= 0) {
    throw ArgumentError.value(weightKg, 'weightKg', 'must be positive');
  }
  if (heightCm <= 0) {
    throw ArgumentError.value(heightCm, 'heightCm', 'must be positive');
  }
  if (ageYears < 0 || ageYears > 130) {
    throw ArgumentError.value(ageYears, 'ageYears', 'must be a plausible age');
  }
  final base = 10 * weightKg + 6.25 * heightCm - 5 * ageYears;
  return sex == Sex.male ? base + 5 : base - 161;
}

/// The multiplier on resting burn implied by an average daily step count.
///
/// The familiar activity factors are a five-step ladder from 1.2 (sedentary) to
/// 1.9 (athlete), and steps are the one input the phone can measure honestly.
/// Interpolated between the rungs rather than snapped to them: a lifter who
/// averages 7,499 steps and one who averages 7,500 do not differ by 175 kcal,
/// and a ladder would make the estimate jump every time they crossed a line.
///
/// Capped at the top rung. Beyond about 15,000 steps the extra burn is real but
/// the factor stops tracking it, and the adaptive estimate takes over long
/// before that matters.
double activityFactor(int stepsPerDay) {
  if (stepsPerDay < 0) {
    throw ArgumentError.value(stepsPerDay, 'stepsPerDay', 'must not be negative');
  }
  const anchors = <(int, double)>[
    (0, 1.2),
    (5000, 1.375),
    (7500, 1.55),
    (10000, 1.725),
    (12500, 1.9),
  ];
  if (stepsPerDay >= anchors.last.$1) return anchors.last.$2;

  for (var i = 0; i < anchors.length - 1; i++) {
    final (steps, factor) = anchors[i];
    final (nextSteps, nextFactor) = anchors[i + 1];
    if (stepsPerDay < nextSteps) {
      final t = (stepsPerDay - steps) / (nextSteps - steps);
      return factor + (nextFactor - factor) * t;
    }
  }
  return anchors.last.$2;
}

/// The starting estimate, before there are enough logs to measure anything.
///
/// Deliberately a guess with a known shape: resting burn times how much the
/// lifter moves. It is what the app shows while it says "estimating", and it is
/// replaced — not adjusted — as soon as a fortnight of food logs exists.
double seedTdee({
  required double weightKg,
  required double heightCm,
  required int ageYears,
  required Sex sex,
  int stepsPerDay = 0,
}) =>
    basalMetabolicRate(
      weightKg: weightKg,
      heightCm: heightCm,
      ageYears: ageYears,
      sex: sex,
    ) *
    activityFactor(stepsPerDay);

/// One day's food log. Days with no log are absent from the list rather than
/// present with zero: nobody ate nothing, they just did not write it down, and
/// averaging the zero in would understate intake and so understate TDEE.
class IntakeDay {
  const IntakeDay({required this.date, required this.kcal});

  final DateTime date;
  final int kcal;
}

/// Why the TDEE figure is what it is.
enum TdeeStatus {
  /// Seeded from Mifflin-St Jeor, because there is not enough logged food to
  /// measure anything yet.
  estimating,

  /// Measured from intake and weight change.
  measured,

  /// Too few days logged in the last week to update, so the previous figure
  /// stands. The spec's rule: fewer than five of seven and the app says so
  /// rather than quietly drifting on bad data.
  notEnoughLogs,
}

/// What the engine currently believes about maintenance calories.
class TdeeEstimate {
  const TdeeEstimate({
    required this.kcal,
    required this.status,
    required this.loggedDays,
  });

  final double kcal;
  final TdeeStatus status;

  /// How many days in the window carried a food log.
  final int loggedDays;

  bool get isMeasured => status == TdeeStatus.measured;

  @override
  String toString() => 'TdeeEstimate(${kcal.round()} kcal, $status, '
      '$loggedDays logged)';
}

/// Maintenance calories implied by what was eaten and what the scale did.
///
/// ```
/// TDEE_obs = avg_intake - (weight change in kcal) / days
/// ```
///
/// If someone ate 2,400 a day and lost half a kilo a week, they were burning
/// 2,400 plus the 550-odd a day that half-kilo represents. This is the whole
/// idea behind adaptive TDEE: it needs no equation about the person, only
/// arithmetic about their fortnight.
///
/// [weeklyRateKg] comes from [weeklyRateKg] on the trend — a fitted rate, not
/// two scale readings, because a single salty dinner at the end of the window
/// would otherwise move maintenance by hundreds of calories.
double observedTdee({
  required double averageIntakeKcal,
  required double weeklyRateKg,
}) =>
    averageIntakeKcal - weeklyRateKg * kcalPerKg / 7;

/// Updates the running estimate, damped so it follows real change without
/// chasing noise.
///
/// The spec's 0.25: a quarter of the way from the old figure to the new one,
/// once a week. A fortnight of genuinely different data moves it most of the
/// way; one odd week barely moves it at all.
double dampedTdee({
  required double previous,
  required double observed,
  double damping = 0.25,
}) {
  if (damping <= 0 || damping > 1) {
    throw ArgumentError.value(damping, 'damping', 'must be in (0, 1]');
  }
  return previous + damping * (observed - previous);
}

/// The engine's current view of maintenance, from whatever evidence exists.
///
/// Falls back to [seed] and says so rather than guessing from thin data. Two
/// separate guards, because they fail differently:
///
///   * fewer than [minimumDays] logged days in the whole window — there is no
///     measurement to make, so the seed stands and the app says "estimating";
///   * fewer than [minimumRecentDays] of the last seven — there *is* a previous
///     figure, and the honest move is to keep it and say why rather than update
///     it from a week of half-logged days.
TdeeEstimate estimateTdee({
  required List<IntakeDay> intake,
  required List<TrendPoint> trend,
  required double seed,
  double? previous,
  int days = 14,
  int minimumDays = 10,
  int minimumRecentDays = 5,
}) {
  if (trend.isEmpty) {
    return TdeeEstimate(
      kcal: previous ?? seed,
      status: TdeeStatus.estimating,
      loggedDays: 0,
    );
  }

  final last = trend.last.date;
  final from = last.subtract(Duration(days: days - 1));
  final window = intake.where((day) {
    final date = DateTime.utc(day.date.year, day.date.month, day.date.day);
    return !date.isBefore(from) && !date.isAfter(last);
  }).toList();

  if (window.length < minimumDays) {
    return TdeeEstimate(
      kcal: previous ?? seed,
      status: TdeeStatus.estimating,
      loggedDays: window.length,
    );
  }

  final weekFrom = last.subtract(const Duration(days: 6));
  final recent = window.where((day) {
    final date = DateTime.utc(day.date.year, day.date.month, day.date.day);
    return !date.isBefore(weekFrom);
  }).length;
  if (recent < minimumRecentDays) {
    return TdeeEstimate(
      kcal: previous ?? seed,
      status: TdeeStatus.notEnoughLogs,
      loggedDays: window.length,
    );
  }

  final rate = weeklyRateKg(trend, days: days);
  if (rate == null) {
    return TdeeEstimate(
      kcal: previous ?? seed,
      status: TdeeStatus.estimating,
      loggedDays: window.length,
    );
  }

  final average =
      window.map((d) => d.kcal).reduce((a, b) => a + b) / window.length;
  final observed =
      observedTdee(averageIntakeKcal: average, weeklyRateKg: rate);

  return TdeeEstimate(
    kcal: previous == null
        ? observed
        : dampedTdee(previous: previous, observed: observed),
    status: TdeeStatus.measured,
    loggedDays: window.length,
  );
}

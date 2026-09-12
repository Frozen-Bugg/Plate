import 'trend.dart';

/// Calories per gram. Fibre and alcohol come later, with the food database.
const kcalPerGramProtein = 4.0;
const kcalPerGramCarb = 4.0;
const kcalPerGramFat = 9.0;

/// A day's targets: what to eat, and how to split it.
class MacroTarget {
  const MacroTarget({
    required this.kcal,
    required this.proteinG,
    required this.fatG,
    required this.carbG,
    required this.flooredAtBmr,
  });

  final int kcal;
  final int proteinG;
  final int fatG;
  final int carbG;

  /// Whether the deficit was cut short to keep intake at or above resting burn.
  /// The UI should say so — a target that quietly ignores the phase is worse
  /// than one that explains itself.
  final bool flooredAtBmr;

  /// What the split actually adds up to. Rounding each macro to a whole gram
  /// moves this a few kcal off [kcal]; the grams are what a lifter weighs out,
  /// so they are the numbers that get to be round.
  int get kcalFromMacros => (proteinG * kcalPerGramProtein +
          carbG * kcalPerGramCarb +
          fatG * kcalPerGramFat)
      .round();

  @override
  String toString() =>
      'MacroTarget($kcal kcal, P${proteinG}g C${carbG}g F${fatG}g)';
}

/// How hard to push the phase, within the band the spec allows.
///
/// 0 is the gentle end of the range, 1 the aggressive end, 0.5 the middle —
/// which is the default because the middle of a sensible range is a sensible
/// place to start, and every number here is an editable suggestion anyway.
typedef Intensity = double;

/// The calorie adjustment a phase asks for, in kcal/day off maintenance.
///
/// Straight from docs/PLAN.md §6: a cut runs 300–500 down, a lean bulk 150–300
/// up, maintenance sits on it.
({double min, double max}) phaseAdjustment(WeightPhase phase) =>
    switch (phase) {
      WeightPhase.cut => (min: -500, max: -300),
      WeightPhase.maintain => (min: 0, max: 0),
      WeightPhase.bulk => (min: 150, max: 300),
    };

/// Protein, in grams per kilogram of bodyweight, by phase.
///
/// Highest on a cut: protein is what makes the difference between losing fat
/// and losing the muscle the training is for.
({double min, double max}) proteinPerKg(WeightPhase phase) => switch (phase) {
      WeightPhase.cut => (min: 2.0, max: 2.4),
      WeightPhase.maintain => (min: 1.6, max: 2.2),
      WeightPhase.bulk => (min: 1.6, max: 2.0),
    };

/// The day's targets for a phase.
///
/// Protein is set first because it is the one macro with a floor worth
/// defending, fat next because hormones need a minimum, and carbohydrate takes
/// whatever is left — it is the fuel for the training, and the training is the
/// point.
///
/// The deficit is never allowed to take intake below resting burn
/// (docs/PLAN.md §11). A lifter who wants to lose faster than that can, but not
/// by the app proposing it.
MacroTarget dailyTarget({
  required double tdeeKcal,
  required WeightPhase phase,
  required double weightKg,
  required double bmrKcal,
  Intensity intensity = 0.5,
  double fatPerKgFloor = 0.6,
  double fatPerKg = 0.8,
}) {
  if (weightKg <= 0) {
    throw ArgumentError.value(weightKg, 'weightKg', 'must be positive');
  }
  if (intensity < 0 || intensity > 1) {
    throw ArgumentError.value(intensity, 'intensity', 'must be in [0, 1]');
  }
  if (fatPerKg < fatPerKgFloor) {
    throw ArgumentError.value(
      fatPerKg,
      'fatPerKg',
      'must not be below the floor of $fatPerKgFloor',
    );
  }

  // Intensity runs from gentle to aggressive, which on a cut means from the
  // small deficit to the large one — the more negative end.
  final adjustment = phaseAdjustment(phase);
  final change = phase == WeightPhase.cut
      ? adjustment.max + (adjustment.min - adjustment.max) * intensity
      : adjustment.min + (adjustment.max - adjustment.min) * intensity;

  final wanted = tdeeKcal + change;
  final flooredAtBmr = wanted < bmrKcal;
  final kcal = flooredAtBmr ? bmrKcal : wanted;

  final protein = proteinPerKg(phase);
  final proteinG =
      weightKg * (protein.min + (protein.max - protein.min) * intensity);
  final fatG = weightKg * fatPerKg;

  final remaining =
      kcal - proteinG * kcalPerGramProtein - fatG * kcalPerGramFat;
  // A very small person on a large deficit can leave nothing for carbohydrate.
  // Report zero rather than a negative target and let the UI say the split is
  // tight; inventing carbs to fill a gap would break the calorie total.
  final carbG = remaining <= 0 ? 0.0 : remaining / kcalPerGramCarb;

  return MacroTarget(
    kcal: kcal.round(),
    proteinG: proteinG.round(),
    fatG: fatG.round(),
    carbG: carbG.round(),
    flooredAtBmr: flooredAtBmr,
  );
}

/// A proposed change to the calorie target, with the reasoning attached.
///
/// The spec's rule: two weeks off target, then propose ±100–150 kcal *with the
/// maths shown*. The engine produces the number and the sentence's raw
/// material; the coach does the talking and the lifter approves it.
class CalorieProposal {
  const CalorieProposal({
    required this.fromKcal,
    required this.toKcal,
    required this.observedRatePercent,
    required this.targetRatePercent,
  });

  final int fromKcal;
  final int toKcal;

  /// What the trend actually did, %BW/week.
  final double observedRatePercent;

  /// The nearest edge of the phase's band — what it should have done.
  final double targetRatePercent;

  int get deltaKcal => toKcal - fromKcal;

  @override
  String toString() => 'CalorieProposal($fromKcal → $toKcal kcal)';
}

/// Suggests a calorie change when the trend has sat outside the phase's band.
///
/// Returns null when the trend is on target, when there is not enough history
/// to judge, or when the change would be smaller than [minimumStepKcal] — a
/// 40 kcal adjustment is inside the noise of both the food log and the scale,
/// and proposing it would teach the lifter to ignore proposals.
///
/// The size is derived, not picked: the gap between the observed rate and the
/// band, converted to calories through [kcalPerKg], then clamped to the spec's
/// 100–150 window so a wild fortnight cannot produce a wild suggestion.
CalorieProposal? proposeCalorieChange({
  required List<TrendPoint> trend,
  required WeightPhase phase,
  required int currentKcal,
  double minimumStepKcal = 100,
  double maximumStepKcal = 150,
  int days = 14,
}) {
  final verdict = judgeTrend(trend, phase, days: days);
  if (verdict == TrendVerdict.unknown || verdict == TrendVerdict.onTarget) {
    return null;
  }

  final rate = weeklyRatePercent(trend, days: days);
  if (rate == null) return null;
  final current = trend.last.trendKg;
  if (current <= 0) return null;

  // The edge of the band it missed, and by how much.
  final edge = verdict == TrendVerdict.above
      ? phase.maxPercentPerWeek
      : phase.minPercentPerWeek;
  final gapKgPerWeek = (rate - edge) / 100 * current;
  final gapKcalPerDay = gapKgPerWeek * 7700 / 7;

  final size = gapKcalPerDay.abs().clamp(minimumStepKcal, maximumStepKcal);
  // Gaining too fast means eating less, and vice versa.
  final delta = gapKcalPerDay > 0 ? -size : size;

  return CalorieProposal(
    fromKcal: currentKcal,
    toKcal: (currentKcal + delta).round(),
    observedRatePercent: rate,
    targetRatePercent: edge,
  );
}

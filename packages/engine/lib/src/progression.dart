import 'set_log.dart';

/// Which rule decides the next target for an exercise.
///
/// Only [double] and [linear] are implemented in engine v1. The rest are in
/// the spec and arrive with engine v2 (see docs/PLAN.md §5).
enum ProgressionModel {
  double_('double'),
  linear('linear'),
  rpeAutoregulated('rpe'),
  trainingMax('training_max');

  const ProgressionModel(this.wireName);

  /// The value stored in `template_exercises.progression_model`.
  final String wireName;

  static ProgressionModel fromWire(String value) => values.firstWhere(
        (m) => m.wireName == value,
        orElse: () => throw ArgumentError.value(
          value,
          'value',
          'unknown progression model',
        ),
      );
}

/// Why the engine chose the target it did. Shown to the lifter, and given to
/// the coach so it explains rather than invents.
enum ProgressionReason {
  /// Top of the rep range hit on every set at or under target effort.
  loadIncreased,

  /// Same load, aim for more reps.
  repsIncreased,

  /// Held: the last exposure did not earn a step up.
  held,

  /// Backed off after repeated failures.
  deloaded,

  /// No history for this exercise yet.
  firstExposure,
}

/// What to put in front of the lifter next time this exercise comes up.
class NextTarget {
  const NextTarget({
    required this.loadKg,
    required this.reps,
    required this.reason,
  });

  final double loadKg;

  /// The rep target for each working set — the bottom of the range after a
  /// load increase, otherwise what they should be chasing.
  final int reps;

  final ProgressionReason reason;

  @override
  bool operator ==(Object other) =>
      other is NextTarget &&
      other.loadKg == loadKg &&
      other.reps == reps &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(loadKg, reps, reason);

  @override
  String toString() => 'NextTarget(${loadKg}kg x $reps, ${reason.name})';
}

/// Double progression — the default, and the right model for most hypertrophy
/// work on dumbbells and machines.
///
/// Work up the rep range at a fixed load. Once every working set reaches the
/// top of the range at or under the target effort, add the smallest load step
/// the equipment allows and drop back to the bottom of the range.
///
/// Effort is the gate that stops the load climbing on a grinding session: a
/// set at the top of the range but above target RPE earns nothing.
class DoubleProgression {
  const DoubleProgression({
    required this.repMin,
    required this.repMax,
    required this.loadStepKg,
    this.targetRir,
  });

  final int repMin;
  final int repMax;

  /// Smallest usable jump for this equipment — `exercises.load_step_kg`.
  final double loadStepKg;

  /// Reps in reserve the sets are meant to leave. Null means effort is not
  /// judged, and only the rep target gates the increase.
  final double? targetRir;

  NextTarget next({Exposure? last}) {
    if (last == null || last.isEmpty) {
      return NextTarget(
        loadKg: 0,
        reps: repMin,
        reason: ProgressionReason.firstExposure,
      );
    }

    final load = last.prescribedLoadKg;
    final everySetAtTop = last.sets.every((s) => s.reps >= repMax);

    // An unrated set cannot disprove the effort gate; a rated one can.
    final withinEffort = targetRir == null ||
        last.sets.every((s) => s.rir == null || s.rir! >= targetRir!);

    if (everySetAtTop && withinEffort) {
      return NextTarget(
        loadKg: load + loadStepKg,
        reps: repMin,
        reason: ProgressionReason.loadIncreased,
      );
    }

    // Hold the load and chase one more rep than the weakest set managed,
    // never past the top of the range.
    final weakest = last.sets.map((s) => s.reps).reduce((a, b) => a < b ? a : b);
    final target = weakest + 1 > repMax ? repMax : weakest + 1;
    return NextTarget(
      loadKg: load,
      reps: target < repMin ? repMin : target,
      reason: everySetAtTop
          ? ProgressionReason.held
          : ProgressionReason.repsIncreased,
    );
  }
}

/// Linear progression — add a fixed amount every session. Suits the first
/// three to six months, when recovery outpaces the bar.
///
/// Two failed sessions in a row cut the load by 10%; the spec's alternative is
/// to switch to double progression, which is the caller's call to make.
class LinearProgression {
  const LinearProgression({
    required this.incrementKg,
    required this.reps,
    this.failuresBeforeDeload = 2,
    this.deloadFraction = 0.10,
  });

  /// Per the spec: 2.5 kg for upper-body lifts, 5 kg for lower. The caller
  /// supplies it — the engine does not guess anatomy from an exercise name.
  final double incrementKg;

  /// The prescribed reps per working set; linear holds the range fixed and
  /// moves the load instead.
  final int reps;

  final int failuresBeforeDeload;

  /// How much to strip on a reset, as a fraction of the current load.
  final double deloadFraction;

  /// [consecutiveFailures] counts sessions already failed before this one,
  /// as held in `progression_state.stall_count`.
  NextTarget next({Exposure? last, int consecutiveFailures = 0}) {
    if (last == null || last.isEmpty) {
      return NextTarget(
        loadKg: 0,
        reps: reps,
        reason: ProgressionReason.firstExposure,
      );
    }

    final load = last.prescribedLoadKg;
    final madeIt = last.sets.every((s) => s.reps >= reps);

    if (madeIt) {
      return NextTarget(
        loadKg: load + incrementKg,
        reps: reps,
        reason: ProgressionReason.loadIncreased,
      );
    }

    if (consecutiveFailures + 1 >= failuresBeforeDeload) {
      return NextTarget(
        loadKg: load * (1 - deloadFraction),
        reps: reps,
        reason: ProgressionReason.deloaded,
      );
    }

    // First miss: give the same load another honest attempt.
    return NextTarget(
      loadKg: load,
      reps: reps,
      reason: ProgressionReason.held,
    );
  }
}

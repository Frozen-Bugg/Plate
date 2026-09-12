import 'e1rm.dart';

/// One working set as it was actually performed.
///
/// Mirrors the columns of the `sets` table that the engine needs; it is
/// deliberately not the Drift row, so the engine stays free of the database.
class SetLog {
  const SetLog({
    required this.weightKg,
    required this.reps,
    this.rir,
  });

  final double weightKg;
  final int reps;

  /// Reps left in reserve. Null when the lifter did not rate the set — the
  /// engine then falls back to rules that do not need effort.
  final double? rir;

  /// Effort as RPE, for callers that prefer it. Null when [rir] is null.
  double? get rpe => rir == null ? null : rirToRpe(rir!);

  /// Estimated one-rep max for this set, counting reps in reserve when the
  /// lifter rated it.
  double get estimatedOneRepMax => rir == null
      ? e1rm(loadKg: weightKg, reps: reps)
      : e1rmWithRir(loadKg: weightKg, reps: reps, rir: rir!);

  @override
  String toString() =>
      'SetLog(${weightKg}kg x $reps${rir == null ? '' : ' @RIR $rir'})';
}

/// One session's worth of work on a single exercise — what the engine looks at
/// when deciding the next target.
///
/// "Exposure" rather than "session" because the same exercise can come up more
/// than once in a week, and progression counts appearances, not calendar days.
class Exposure {
  const Exposure({required this.sets, this.loadKg});

  /// The working sets, in the order they were performed. Warm-ups are excluded
  /// by the caller: they say nothing about progression.
  final List<SetLog> sets;

  /// The load the exercise was prescribed at, when it differs from what was
  /// lifted. Defaults to the heaviest working set.
  final double? loadKg;

  double get prescribedLoadKg =>
      loadKg ?? sets.map((s) => s.weightKg).reduce((a, b) => a > b ? a : b);

  /// The best estimated one-rep max across the working sets. This is the
  /// number progression and stall detection compare between exposures.
  double get bestE1rm =>
      sets.map((s) => s.estimatedOneRepMax).reduce((a, b) => a > b ? a : b);

  /// The hardest the lifter rated any set, as RPE. Null when none were rated.
  double? get hardestRpe {
    final rated = sets.where((s) => s.rpe != null).map((s) => s.rpe!);
    return rated.isEmpty ? null : rated.reduce((a, b) => a > b ? a : b);
  }

  bool get isEmpty => sets.isEmpty;
}

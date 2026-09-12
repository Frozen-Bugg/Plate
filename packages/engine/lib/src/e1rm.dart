/// Estimated one-rep max, by the Epley formula.
///
/// ```
/// e1RM = load × (1 + reps / 30)
/// ```
///
/// A single rep returns the load itself. Accuracy falls away above about ten
/// reps, where the formula starts to flatter the lifter — treat a 20-rep set's
/// estimate as a direction, not a number.
double e1rm({required double loadKg, required int reps}) {
  if (reps < 1) {
    throw ArgumentError.value(reps, 'reps', 'must be at least 1');
  }
  if (loadKg < 0) {
    throw ArgumentError.value(loadKg, 'loadKg', 'must not be negative');
  }
  return loadKg * (1 + reps / 30);
}

/// Estimated one-rep max that counts the reps left in reserve.
///
/// ```
/// e1RM_rir = load × (1 + (reps + RIR) / 30)
/// ```
///
/// A set of 8 with 2 left is worth the same as a set of 10 taken to failure,
/// which is what makes submaximal sets comparable across sessions. With
/// [rir] of 0 this is identical to [e1rm].
double e1rmWithRir({
  required double loadKg,
  required int reps,
  required double rir,
}) {
  if (rir < 0) {
    throw ArgumentError.value(rir, 'rir', 'must not be negative');
  }
  if (reps < 1) {
    throw ArgumentError.value(reps, 'reps', 'must be at least 1');
  }
  if (loadKg < 0) {
    throw ArgumentError.value(loadKg, 'loadKg', 'must not be negative');
  }
  return loadKg * (1 + (reps + rir) / 30);
}

/// RPE and RIR are two names for the same judgement: RPE 8 is 2 reps in
/// reserve. The app stores RIR; templates and coaching talk in RPE.
double rpeToRir(double rpe) => 10 - rpe;

/// The inverse of [rpeToRir].
double rirToRpe(double rir) => 10 - rir;

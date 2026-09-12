import 'set_log.dart';

/// Whether an exercise has stopped moving.
///
/// From the spec: *stalled = no e1RM gain across 3 exposures at the same or
/// higher RPE*. Both halves matter. Flat e1RM while the sets get easier is a
/// lifter holding back, not a plateau; flat e1RM while they get harder is the
/// real thing, and the one worth acting on.
///
/// [exposures] is chronological, oldest first. Returns false until there are
/// at least [window] exposures to judge — a new exercise has not stalled, it
/// has simply not been done enough.
bool isStalled(List<Exposure> exposures, {int window = 3}) {
  if (window < 1) {
    throw ArgumentError.value(window, 'window', 'must be at least 1');
  }
  if (exposures.length < window) return false;

  final recent = exposures.sublist(exposures.length - window);
  final earlier = exposures.sublist(0, exposures.length - window);

  // What the recent run has to beat. With no history behind it, the first of
  // the run sets the bar for the ones after it.
  final benchmark = earlier.isEmpty
      ? recent.first
      : earlier.reduce((a, b) => a.bestE1rm >= b.bestE1rm ? a : b);

  // Floating point: a gain has to be worth more than rounding noise.
  const epsilon = 1e-9;
  final gained = recent.any((e) => e.bestE1rm > benchmark.bestE1rm + epsilon);
  if (gained) return false;

  // Not a stall if the work got easier — that is unrated or backed-off effort,
  // and the fix is to push, not to deload.
  final bar = benchmark.hardestRpe;
  if (bar == null) return true;
  return recent.every((e) {
    final rpe = e.hardestRpe;
    return rpe == null || rpe >= bar;
  });
}

/// How many of the most recent exposures have failed to beat the best e1RM
/// before them. Feeds `progression_state.stall_count`.
int stallCount(List<Exposure> exposures) {
  if (exposures.isEmpty) return 0;
  var best = exposures.first.bestE1rm;
  var count = 0;
  for (final exposure in exposures.skip(1)) {
    if (exposure.bestE1rm > best) {
      best = exposure.bestE1rm;
      count = 0;
    } else {
      count++;
    }
  }
  return count;
}

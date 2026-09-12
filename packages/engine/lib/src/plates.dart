/// A standard metric gym's plates, heaviest first. Loading is greedy from the
/// top, which is optimal for this set because every plate is a multiple of the
/// ones below it.
const defaultPlatesKg = <double>[25, 20, 15, 10, 5, 2.5, 1.25];

/// A men's Olympic barbell.
const defaultBarKg = 20.0;

/// What to hang on each end of the bar, and what that actually weighs.
class PlateLoad {
  const PlateLoad({
    required this.requestedKg,
    required this.barKg,
    required this.perSide,
  });

  /// What the lifter asked for.
  final double requestedKg;

  final double barKg;

  /// Plates for one end, heaviest first. Mirror them on the other end.
  final List<double> perSide;

  /// What the bar will actually weigh once loaded.
  double get totalKg =>
      barKg + perSide.fold<double>(0, (sum, plate) => sum + plate) * 2;

  /// How far short of the request this lands. Zero when it can be made
  /// exactly; positive when the plates cannot get there.
  double get shortfallKg {
    final gap = requestedKg - totalKg;
    return gap < 0 ? 0 : gap;
  }

  bool get isExact => (requestedKg - totalKg).abs() < 1e-9;

  /// True when the request is lighter than the bar itself, so there is nothing
  /// to load and nothing to be done about it.
  bool get belowBar => requestedKg < barKg;

  @override
  String toString() => 'PlateLoad(${totalKg}kg = $barKg + $perSide per side)';
}

/// Works out what to load for [targetKg].
///
/// Greedy from the heaviest plate down. With a standard set this is optimal;
/// with an unusual one it can leave a gap it could have closed, which is why
/// [PlateLoad.shortfallKg] exists rather than the result pretending to be
/// exact.
///
/// The lifter is told the truth about what is achievable rather than being
/// given a number the bar cannot make: gyms have finite plates, and 61 kg on a
/// 20 kg bar is not a weight.
PlateLoad platesFor({
  required double targetKg,
  double barKg = defaultBarKg,
  List<double> availableKg = defaultPlatesKg,
}) {
  if (barKg < 0) {
    throw ArgumentError.value(barKg, 'barKg', 'must not be negative');
  }
  if (targetKg < barKg) {
    return PlateLoad(
      requestedKg: targetKg,
      barKg: barKg,
      perSide: const [],
    );
  }

  final plates = [...availableKg]..sort((a, b) => b.compareTo(a));
  var remaining = (targetKg - barKg) / 2;
  final perSide = <double>[];

  for (final plate in plates) {
    if (plate <= 0) continue;
    // A hair of tolerance, or 0.5 kg of binary floating point error turns into
    // a missing 1.25 plate.
    while (remaining >= plate - 1e-9) {
      perSide.add(plate);
      remaining -= plate;
    }
  }

  return PlateLoad(requestedKg: targetKg, barKg: barKg, perSide: perSide);
}

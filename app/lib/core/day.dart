/// Calendar days, as the Body & Move tables key themselves.
///
/// Those tables store a `date`, not a timestamp: a weigh-in belongs to the day
/// the lifter was standing on the scale, in their own timezone. Everything else
/// in the app stores UTC instants, so the conversion happens here and only
/// here — a day key is built from *local* time on purpose.
library;

/// "2026-09-12" for the day [at] falls on locally. Defaults to today.
String dayKey([DateTime? at]) {
  final local = (at ?? DateTime.now()).toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// The day [offset] days before today, as a key. `daysAgo(1)` is yesterday.
String daysAgo(int offset) =>
    dayKey(DateTime.now().subtract(Duration(days: offset)));

/// Parses a stored day key back to a date.
///
/// Returns a UTC midnight so that arithmetic on it — the engine's day gaps,
/// for instance — never crosses a daylight-saving boundary and loses an hour.
/// It is a label for a day, not an instant in it.
DateTime parseDayKey(String key) {
  final parts = key.split('-');
  if (parts.length != 3) {
    throw FormatException('Not a day key', key);
  }
  return DateTime.utc(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

/// Calendar days, as the Body & Move tables key themselves.
///
/// Those tables store a `date`, not a timestamp: a weigh-in belongs to the day
/// the lifter was standing on the scale, in their own timezone. Everything else
/// in the app stores UTC instants, so the conversion happens here and only
/// here — a day key is built from *local* time on purpose.
library;

import 'package:powersync/powersync.dart' show uuid;
import 'package:uuid/uuid.dart' show Namespace;

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

/// The row id for a table that keeps one row per day per user.
///
/// Derived from the owner and the day rather than generated, so the same day
/// always lands on the same id — on this device, on the next one, and after a
/// reinstall. Every one of these tables has a partial unique index on
/// `(user_id, <day>)`, and a fresh UUIDv7 for a day the server already holds is
/// rejected with 23505 and dropped. That is not hypothetical: it happened the
/// first time `daily_rollup` ran before its rows had finished downloading.
///
/// UUIDv5 over a namespaced string, so it is a real UUID and stays stable
/// across versions of the app.
String dayRowId({
  required String userId,
  required String table,
  required String day,
}) =>
    uuid.v5(Namespace.url.value, 'overload/$table/$userId/$day');

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

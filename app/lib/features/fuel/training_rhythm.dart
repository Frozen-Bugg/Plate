import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../train/sessions_repository.dart';

/// Which days of the week are training days, worked out from what has happened.
///
/// The carb shift needs two facts the app has nowhere else to get: how many
/// sessions there are in a week, and whether today is one of them. A program
/// would answer both, but programs and mesocycles are Phase 5 — so until then
/// this reads the habit out of the log.
///
/// It has to answer *before* the session, not after. Carbohydrate on a training
/// day is fuel for it, and a target that only shifts once the workout is
/// finished has moved the food to the wrong side of the session. So the answer
/// comes from which weekdays are usually trained, not from whether anything has
/// been logged yet today.
class TrainingRhythm {
  const TrainingRhythm({required this.weekdays, required this.trainingToday});

  /// Weekdays usually trained, as DateTime.monday..sunday.
  final Set<int> weekdays;

  /// Whether today counts — a usual day, or an unplanned session already
  /// under way.
  final bool trainingToday;

  int get daysPerWeek => weekdays.length;

  /// Whether there is anything to redistribute. Seven training days have no
  /// rest day to borrow from, and none have nothing to borrow for.
  bool get canShift => daysPerWeek > 0 && daysPerWeek < 7;
}

/// How much of a weekday has to be trained before it counts as a training day.
///
/// Half. A Tuesday trained two weeks in four is a coin toss, and shifting a
/// day's carbohydrate onto a coin toss is worse than not shifting at all.
const _usually = 0.5;

/// How far back to look. Four weeks is long enough to see a rhythm and short
/// enough to follow a change of one.
const _window = 28;

final trainingRhythmProvider = Provider<TrainingRhythm>((ref) {
  final sessions = ref.watch(recentSessionsProvider).value ?? const [];
  final today = parseDayKey(dayKey());
  final from = today.subtract(const Duration(days: _window - 1));

  // How many times each weekday came round in the window, and how many of
  // those were trained. Counting occurrences rather than assuming four keeps
  // the ratio honest when the log is younger than the window.
  final occurrences = <int, int>{};
  for (var i = 0; i < _window; i++) {
    final day = from.add(Duration(days: i));
    occurrences[day.weekday] = (occurrences[day.weekday] ?? 0) + 1;
  }

  final trained = <int, Set<String>>{};
  var startedToday = false;
  for (final session in sessions) {
    final day = session.startedAt.toLocal();
    final key = dayKey(day);
    if (key == dayKey()) startedToday = true;
    if (day.isBefore(from)) continue;
    (trained[day.weekday] ??= <String>{}).add(key);
  }

  final weekdays = <int>{
    for (final MapEntry(key: weekday, value: days) in trained.entries)
      if (days.length >= (occurrences[weekday] ?? 4) * _usually) weekday,
  };

  return TrainingRhythm(
    weekdays: weekdays,
    trainingToday: weekdays.contains(today.weekday) || startedToday,
  );
});

/// Whether [day] is a training day, for a day other than today.
///
/// The Fuel screen can be looking at last Tuesday, and the target it shows has
/// to be the one that was in force then.
bool trainsOn(TrainingRhythm rhythm, String day, List<WorkoutSession> sessions) {
  final date = parseDayKey(day);
  if (day == dayKey()) return rhythm.trainingToday;
  for (final session in sessions) {
    if (dayKey(session.startedAt.toLocal()) == day) return true;
  }
  return rhythm.weekdays.contains(date.weekday);
}

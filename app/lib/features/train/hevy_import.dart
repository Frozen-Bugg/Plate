/// Turns a workout pasted from Hevy into logged history.
///
/// This app no longer logs a workout live — see docs/PLAN.md and
/// templates_screen.dart. Training happens in Hevy, which the lifter already
/// knows; what gets built here is the other half, reading the workout back
/// out afterwards so the engine still has real sets to judge.
///
/// Hevy's own "Copy" share text looks like this:
///
///   Chest triceps
///   Thursday, Aug 20, 2026 at 6:16am
///
///   Incline Bench Press (Dumbbell)
///   Set 1: 30 kg x 9
///   Set 2: 30 kg x 8
///
///   Chest Dip
///   Set 1: 18 reps
///
///   @hevyapp
///   https://hevy.com/workout/i0vKgLtCJmZ
///
/// Nothing here is a model call. The shape is fixed enough that a handful of
/// regexes read it reliably, on the device, with no network and nothing to
/// wait on.
library;

import 'exercises_repository.dart';
import 'logging_repository.dart';
import 'progression_repository.dart';
import 'sessions_repository.dart';

/// One set, as Hevy wrote it. A null [weightKg] means a bodyweight set —
/// "Set 1: 18 reps" — not a set with zero load.
class ParsedHevySet {
  const ParsedHevySet({required this.reps, this.weightKg});

  final int reps;
  final double? weightKg;
}

class ParsedHevyExercise {
  const ParsedHevyExercise({required this.name, required this.sets});

  /// As Hevy named it, equipment tag and all — "Incline Bench Press
  /// (Dumbbell)". Matching against the library strips that tag; creating a
  /// new exercise reads it back for the equipment field.
  final String name;
  final List<ParsedHevySet> sets;
}

class ParsedHevyWorkout {
  const ParsedHevyWorkout({
    required this.title,
    required this.startedAt,
    required this.exercises,
  });

  final String? title;

  /// Local wall-clock time, as Hevy printed it — converted to UTC only when
  /// it is written, same as every other timestamp in the app.
  final DateTime? startedAt;
  final List<ParsedHevyExercise> exercises;
}

/// Raised when the pasted text has nothing readable as a workout in it.
class HevyParseError implements Exception {
  const HevyParseError(this.message);
  final String message;

  @override
  String toString() => message;
}

final _weightRepsLine = RegExp(
  r'^set\s*\d+\s*:\s*([\d.]+)\s*(kgs?|lbs?)\s*[x×]\s*(\d+)',
  caseSensitive: false,
);
final _repsOnlyLine = RegExp(
  r'^set\s*\d+\s*:\s*(\d+)\s*reps?\b',
  caseSensitive: false,
);
final _trailingParenthetical = RegExp(r'\s*\([^)]*\)\s*$');

/// A trailing parenthetical from an exercise name — "Incline Bench Press
/// (Dumbbell)" becomes "Incline Bench Press" — the shape the library's own
/// names are in, and what should actually be matched or created.
String stripEquipmentTag(String name) =>
    name.replaceAll(_trailingParenthetical, '').trim();

/// Best guess at `exercises.equipment` from that same tag, for a new
/// exercise created because nothing in the library matched at all. Anything
/// unrecognised falls through to the caller's own default rather than
/// guessing wrong.
String? equipmentFromTag(String name) {
  final match = RegExp(r'\(([^)]*)\)\s*$').firstMatch(name);
  if (match == null) return null;
  final tag = match.group(1)!.trim().toLowerCase();
  if (equipmentKinds.contains(tag)) return tag;
  return switch (tag) {
    'smith machine' || 'plate loaded' || 'trap bar' => 'machine',
    'resistance band' => 'band',
    'assisted' || 'weighted' => 'bodyweight',
    _ => null,
  };
}

ParsedHevySet? _parseSetLine(String rawLine) {
  final line = rawLine.replaceAll(_trailingParenthetical, '').trim();
  if (_weightRepsLine.firstMatch(line) case final m?) {
    final weight = double.parse(m.group(1)!);
    final unit = m.group(2)!.toLowerCase();
    final reps = int.parse(m.group(3)!);
    // Stored metric everywhere else in the app — converted once, here,
    // rather than carrying a unit through the rest of the pipeline.
    final kg = unit.startsWith('lb') ? weight * 0.45359237 : weight;
    return ParsedHevySet(reps: reps, weightKg: kg);
  }
  if (_repsOnlyLine.firstMatch(line) case final m?) {
    return ParsedHevySet(reps: int.parse(m.group(1)!));
  }
  return null;
}

const _months = {
  'jan': 1,
  'january': 1,
  'feb': 2,
  'february': 2,
  'mar': 3,
  'march': 3,
  'apr': 4,
  'april': 4,
  'may': 5,
  'jun': 6,
  'june': 6,
  'jul': 7,
  'july': 7,
  'aug': 8,
  'august': 8,
  'sep': 9,
  'sept': 9,
  'september': 9,
  'oct': 10,
  'october': 10,
  'nov': 11,
  'november': 11,
  'dec': 12,
  'december': 12,
};

final _dateLine = RegExp(
  r'^\w+,\s*(\w+)\s+(\d{1,2}),\s*(\d{4})\s+at\s+(\d{1,2}):(\d{2})\s*(am|pm)$',
  caseSensitive: false,
);

/// "Thursday, Aug 20, 2026 at 6:16am" → the local instant it names, or null
/// for anything that is not that shape.
DateTime? parseHevyDateLine(String line) {
  final m = _dateLine.firstMatch(line.trim());
  if (m == null) return null;
  final month = _months[m.group(1)!.toLowerCase()];
  if (month == null) return null;
  var hour = int.parse(m.group(4)!) % 12;
  if (m.group(6)!.toLowerCase() == 'pm') hour += 12;
  return DateTime(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(2)!),
    hour,
    int.parse(m.group(5)!),
  );
}

/// Parses whatever was pasted into a workout. Throws [HevyParseError] if
/// nothing in it reads as one — the paste was empty, or garbled, or not from
/// Hevy at all.
ParsedHevyWorkout parseHevyWorkout(String pasted) {
  final lines = <String>[];
  for (final raw in pasted.split('\n')) {
    final line = raw.trim();
    // Hevy's share text ends with its own handle and a link to the workout;
    // neither is part of the workout itself.
    if (line.startsWith('@') ||
        line.startsWith('http://') ||
        line.startsWith('https://')) {
      continue;
    }
    lines.add(line);
  }
  while (lines.isNotEmpty && lines.first.isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }

  if (lines.isEmpty) {
    throw const HevyParseError('Nothing there to read.');
  }

  var dateIndex = -1;
  DateTime? startedAt;
  for (var i = 0; i < lines.length && i < 4; i++) {
    if (parseHevyDateLine(lines[i]) case final parsed?) {
      dateIndex = i;
      startedAt = parsed;
      break;
    }
  }

  String? title;
  int bodyStart;
  if (dateIndex == 0) {
    bodyStart = 1;
  } else if (dateIndex > 0) {
    title = lines[dateIndex - 1].isEmpty ? null : lines[dateIndex - 1];
    bodyStart = dateIndex + 1;
  } else {
    bodyStart = 0;
  }

  final exercises = <ParsedHevyExercise>[];
  String? currentName;
  var currentSets = <ParsedHevySet>[];

  void flush() {
    if (currentName != null && currentSets.isNotEmpty) {
      exercises.add(ParsedHevyExercise(name: currentName!, sets: currentSets));
    }
    currentName = null;
    currentSets = [];
  }

  for (var i = bodyStart; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) continue;
    if (_parseSetLine(line) case final set?) {
      // A set line before any exercise name has been seen cannot belong to
      // anything — skip it rather than guess.
      currentSets.add(set);
    } else {
      flush();
      currentName = line;
    }
  }
  flush();

  if (exercises.isEmpty) {
    throw const HevyParseError(
      'Could not find any exercises in that. Paste it exactly as Hevy '
      'copies it — an exercise name, then "Set 1: 30 kg x 9" underneath.',
    );
  }

  return ParsedHevyWorkout(
    title: title,
    startedAt: startedAt,
    exercises: exercises,
  );
}

/// Writes a parsed workout into history.
///
/// Every exercise is matched against the library first — [equipmentFromTag]
/// and [stripEquipmentTag] exist because Hevy's own names carry the
/// equipment Overload's library keeps as a separate field — and only
/// created when nothing already there fits. Every set goes through
/// [LoggingRepository.logSet], so a personal best and an estimated one-rep
/// max land exactly as they would for a set logged by hand; the engine is
/// then asked to reconsider each exercise trained, the same as finishing a
/// session normally does.
Future<String> importHevyWorkout(
  ParsedHevyWorkout workout, {
  required ExercisesRepository exercises,
  required SessionsRepository sessions,
  required LoggingRepository logging,
  required ProgressionRepository progression,
}) async {
  // No duration in the paste — Hevy's copy does not carry one — so the
  // session is recorded as starting and ending at the same instant rather
  // than inventing a length it was never told.
  final startedAt = (workout.startedAt ?? DateTime.now()).toUtc();
  final sessionId = await sessions.createFinished(
    startedAt: startedAt,
    endedAt: startedAt,
    name: workout.title,
  );

  final trained = <String>{};
  for (final parsed in workout.exercises) {
    final stripped = stripEquipmentTag(parsed.name);
    final matched =
        await exercises.bestMatch(stripped) ??
        await exercises.create(
          name: stripped,
          equipment: equipmentFromTag(parsed.name) ?? 'other',
        );

    final sessionExerciseId = await logging.addExercise(
      sessionId: sessionId,
      exerciseId: matched.id,
    );
    for (final set in parsed.sets) {
      await logging.logSet(
        sessionExerciseId: sessionExerciseId,
        exerciseId: matched.id,
        weightKg: set.weightKg ?? 0,
        reps: set.reps,
      );
    }
    trained.add(matched.id);
  }

  for (final exerciseId in trained) {
    await progression.recompute(exerciseId);
  }

  return sessionId;
}

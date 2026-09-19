import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/train/exercises_repository.dart';
import 'package:overload/features/train/hevy_import.dart';
import 'package:overload/features/train/logging_repository.dart';
import 'package:overload/features/train/progression_repository.dart';
import 'package:overload/features/train/sessions_repository.dart';

import 'support/test_database.dart';

const _pasted = '''
Chest triceps
Thursday, Aug 20, 2026 at 6:16am

Incline Bench Press (Dumbbell)
Set 1: 30 kg x 9
Set 2: 30 kg x 8

Incline Chest Fly (Dumbbell)
Set 1: 10 kg x 14
Set 2: 12.5 kg x 7

Chest Dip
Set 1: 18 reps

Seated Shoulder Press (Machine)
Set 1: 55 kg x 10
Set 2: 55 kg x 6

@hevyapp
https://hevy.com/workout/i0vKgLtCJmZ
''';

void main() {
  group('parseHevyWorkout', () {
    test('reads the title, the date and every exercise', () {
      final workout = parseHevyWorkout(_pasted);

      expect(workout.title, 'Chest triceps');
      expect(
        workout.startedAt,
        DateTime(2026, 8, 20, 6, 16),
        reason: '6:16am is 06:16 in 24h, not 18:16',
      );
      expect(workout.exercises, hasLength(4));
    });

    test('reads weight-and-reps sets in kilograms', () {
      final workout = parseHevyWorkout(_pasted);
      final bench = workout.exercises.first;

      expect(bench.name, 'Incline Bench Press (Dumbbell)');
      expect(bench.sets, hasLength(2));
      expect(bench.sets[0].weightKg, 30);
      expect(bench.sets[0].reps, 9);
      expect(bench.sets[1].weightKg, 30);
      expect(bench.sets[1].reps, 8);
    });

    test('reads a decimal weight', () {
      final workout = parseHevyWorkout(_pasted);
      final fly = workout.exercises[1];

      expect(fly.sets[1].weightKg, 12.5);
      expect(fly.sets[1].reps, 7);
    });

    test('reads a bodyweight set with no weight at all', () {
      final workout = parseHevyWorkout(_pasted);
      final dip = workout.exercises[2];

      expect(dip.name, 'Chest Dip');
      expect(dip.sets, hasLength(1));
      expect(dip.sets.single.weightKg, isNull);
      expect(dip.sets.single.reps, 18);
    });

    test('drops the trailing handle and link', () {
      final workout = parseHevyWorkout(_pasted);
      expect(workout.exercises.every((e) => !e.name.startsWith('@')), isTrue);
    });

    test('converts pounds to kilograms', () {
      final workout = parseHevyWorkout('''
Bench Press
Set 1: 135 lb x 5
''');
      expect(
        workout.exercises.single.sets.single.weightKg,
        closeTo(61.23, 0.01),
      );
    });

    test('reads a workout with no title line', () {
      final workout = parseHevyWorkout('''
Thursday, Aug 20, 2026 at 6:16am

Bench Press
Set 1: 60 kg x 5
''');
      expect(workout.title, isNull);
      expect(workout.startedAt, isNotNull);
      expect(workout.exercises, hasLength(1));
    });

    test('reads a workout with no date at all', () {
      final workout = parseHevyWorkout('''
Bench Press
Set 1: 60 kg x 5
''');
      expect(workout.startedAt, isNull);
      expect(workout.exercises.single.name, 'Bench Press');
    });

    test('throws when there is nothing to read', () {
      expect(() => parseHevyWorkout(''), throwsA(isA<HevyParseError>()));
      expect(
        () => parseHevyWorkout('just some words, no sets'),
        throwsA(isA<HevyParseError>()),
      );
    });
  });

  group('stripEquipmentTag / equipmentFromTag', () {
    test('separates the movement from the equipment Hevy tags it with', () {
      expect(
        stripEquipmentTag('Incline Bench Press (Dumbbell)'),
        'Incline Bench Press',
      );
      expect(equipmentFromTag('Incline Bench Press (Dumbbell)'), 'dumbbell');
    });

    test('leaves a name with no tag alone', () {
      expect(stripEquipmentTag('Chest Dip'), 'Chest Dip');
      expect(equipmentFromTag('Chest Dip'), isNull);
    });
  });

  group('importHevyWorkout', () {
    const userId = 'u-1';
    late TestDatabase db;
    late ExercisesRepository exercises;
    late SessionsRepository sessions;
    late LoggingRepository logging;
    late ProgressionRepository progression;

    setUp(() async {
      db = TestDatabase();
      exercises = ExercisesRepository(db, userId);
      sessions = SessionsRepository(db, userId);
      logging = LoggingRepository(db, userId);
      progression = ProgressionRepository(db, userId);

      // The seeded library ships without an equipment tag in its names —
      // "Bench Press", not "Bench Press (Barbell)" — so matching has to
      // strip Hevy's tag to find it.
      await db
          .into(db.exercises)
          .insert(
            ExercisesCompanion.insert(
              id: const Value('seeded-bench'),
              userId: const Value(null),
              name: 'Incline Bench Press',
              equipment: const Value('dumbbell'),
            ),
          );
    });

    tearDown(() => db.close());

    test('matches an existing exercise despite the equipment tag', () async {
      final workout = parseHevyWorkout(_pasted);
      final sessionId = await importHevyWorkout(
        workout,
        exercises: exercises,
        sessions: sessions,
        logging: logging,
        progression: progression,
      );

      final loggedExercises = await (db.select(
        db.sessionExercises,
      )..where((e) => e.sessionId.equals(sessionId))).get();
      expect(
        loggedExercises.map((e) => e.exerciseId),
        contains('seeded-bench'),
        reason: 'Incline Bench Press (Dumbbell) should reuse the seeded row',
      );
    });

    test('creates a new exercise, with the tag as its equipment, when '
        'nothing matches', () async {
      final workout = parseHevyWorkout(_pasted);
      await importHevyWorkout(
        workout,
        exercises: exercises,
        sessions: sessions,
        logging: logging,
        progression: progression,
      );

      final created = await exercises.byName('Seated Shoulder Press');
      expect(created, isNotNull);
      expect(created!.equipment, 'machine');
    });

    test(
      'writes every set, including a bodyweight one with no weight',
      () async {
        final workout = parseHevyWorkout(_pasted);
        final sessionId = await importHevyWorkout(
          workout,
          exercises: exercises,
          sessions: sessions,
          logging: logging,
          progression: progression,
        );

        final dip = await exercises.byName('Chest Dip');
        final dipExercise =
            await (db.select(db.sessionExercises)
                  ..where((e) => e.sessionId.equals(sessionId))
                  ..where((e) => e.exerciseId.equals(dip!.id)))
                .getSingle();
        final sets = await (db.select(
          db.workoutSets,
        )..where((s) => s.sessionExerciseId.equals(dipExercise.id))).get();

        expect(sets, hasLength(1));
        expect(sets.single.weightKg, 0);
        expect(sets.single.reps, 18);
      },
    );

    test(
      'records the session as already finished, at the pasted time',
      () async {
        final workout = parseHevyWorkout(_pasted);
        final sessionId = await importHevyWorkout(
          workout,
          exercises: exercises,
          sessions: sessions,
          logging: logging,
          progression: progression,
        );

        final session = await (db.select(
          db.sessions,
        )..where((s) => s.id.equals(sessionId))).getSingle();
        expect(session.name, 'Chest triceps');
        expect(session.endedAt, isNotNull);
        expect(session.startedAt, workout.startedAt!.toUtc());
      },
    );

    test('leaves the engine with a real target for what was trained', () async {
      final workout = parseHevyWorkout(_pasted);
      await importHevyWorkout(
        workout,
        exercises: exercises,
        sessions: sessions,
        logging: logging,
        progression: progression,
      );

      final state = await (db.select(
        db.progressionStates,
      )..where((p) => p.exerciseId.equals('seeded-bench'))).getSingleOrNull();
      expect(
        state,
        isNotNull,
        reason:
            'importing should ask the engine to reconsider, same as '
            'finishing a session normally does',
      );
    });
  });
}

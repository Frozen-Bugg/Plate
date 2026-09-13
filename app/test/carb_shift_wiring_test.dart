import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/fuel/targets_repository.dart';
import 'package:overload/features/fuel/training_rhythm.dart';
import 'package:overload/features/train/sessions_repository.dart';

/// That the carb shift reaches the rings.
///
/// The engine's arithmetic is tested in packages/engine. This is the wiring —
/// which is where it was broken before: the column was stored, editable, and
/// read by nothing at all.

final _epoch = DateTime.utc(2026, 9, 1);

NutritionTarget _target({int? shiftPct}) => NutritionTarget(
  id: 't',
  createdAt: _epoch,
  updatedAt: _epoch,
  userId: 'u',
  effectiveFrom: '2026-09-01',
  kcal: 2181,
  proteinG: 174,
  carbG: 225,
  fatG: 65,
  source: 'engine',
  trainingDayCarbShiftPct: shiftPct,
);

ProviderContainer _container({
  int? shiftPct,
  required Set<int> weekdays,
  required bool trainingToday,
}) => ProviderContainer(
  overrides: [
    targetHistoryProvider.overrideWith(
      (ref) => Stream.value([_target(shiftPct: shiftPct)]),
    ),
    recentSessionsProvider.overrideWith((ref) => Stream.value(const [])),
    trainingRhythmProvider.overrideWithValue(
      TrainingRhythm(weekdays: weekdays, trainingToday: trainingToday),
    ),
  ],
);

void main() {
  test('no shift set leaves the target exactly as stored', () async {
    final container = _container(weekdays: {1, 3, 5, 6}, trainingToday: true);
    addTearDown(container.dispose);
    // A StreamProvider read synchronously is still loading, and a target that
    // has not arrived yet is indistinguishable from no target at all. The
    // listen keeps it alive long enough to emit — without a subscriber it is
    // disposed mid-load and the future never completes.
    container.listen(targetHistoryProvider, (_, _) {});
    await container.read(targetHistoryProvider.future);

    final target = container.read(targetForDayProvider('2026-09-14'))!;
    expect(target.shifted, isFalse);
    expect(target.carbG, 225);
    expect(target.kcal, 2181);
  });

  test('a training day borrows carbohydrate from the rest days', () async {
    final container = _container(
      shiftPct: 15,
      weekdays: {1, 3, 5, 6},
      trainingToday: true,
    );
    addTearDown(container.dispose);
    // A StreamProvider read synchronously is still loading, and a target that
    // has not arrived yet is indistinguishable from no target at all. The
    // listen keeps it alive long enough to emit — without a subscriber it is
    // disposed mid-load and the future never completes.
    container.listen(targetHistoryProvider, (_, _) {});
    await container.read(targetHistoryProvider.future);

    final target = container.read(targetForDayProvider('2026-09-14'))!;
    expect(target.shifted, isTrue);
    expect(target.isTrainingDay, isTrue);
    // Three rest days give up 33.75 g each, split across four sessions.
    expect(target.carbG, closeTo(250, 1));
    expect(target.kcal, greaterThan(2181));
    // The stored row is untouched — it is the week's target, not the day's.
    expect(target.baseCarbG, 225);
  });

  test('a rest day gives some up', () async {
    final container = _container(
      shiftPct: 15,
      weekdays: {1, 3, 5, 6},
      trainingToday: false,
    );
    addTearDown(container.dispose);
    // A StreamProvider read synchronously is still loading, and a target that
    // has not arrived yet is indistinguishable from no target at all. The
    // listen keeps it alive long enough to emit — without a subscriber it is
    // disposed mid-load and the future never completes.
    container.listen(targetHistoryProvider, (_, _) {});
    await container.read(targetHistoryProvider.future);

    final target = container.read(targetForDayProvider('2026-09-15'))!;
    expect(target.shifted, isTrue);
    expect(target.carbG, 191);
    expect(target.kcal, lessThan(2181));
  });

  // One container each: two in a loop left the second's stream waiting on a
  // subscription the first had already torn down.
  test('protein does not move on a training day', () async {
    final container = _container(
      shiftPct: 25,
      weekdays: {1, 3, 5},
      trainingToday: true,
    );
    addTearDown(container.dispose);
    container.listen(targetHistoryProvider, (_, _) {});
    await container.read(targetHistoryProvider.future);

    final target = container.read(targetForDayProvider('2026-09-14'))!;
    expect(target.proteinG, 174);
    expect(target.fatG, 65);
  });

  test('nor on a rest day', () async {
    final container = _container(
      shiftPct: 25,
      weekdays: {1, 3, 5},
      trainingToday: false,
    );
    addTearDown(container.dispose);
    container.listen(targetHistoryProvider, (_, _) {});
    await container.read(targetHistoryProvider.future);

    final target = container.read(targetForDayProvider('2026-09-14'))!;
    expect(target.proteinG, 174);
    expect(target.fatG, 65);
  });

  test('training every day has no rest day to borrow from', () async {
    final container = _container(
      shiftPct: 15,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      trainingToday: true,
    );
    addTearDown(container.dispose);
    // A StreamProvider read synchronously is still loading, and a target that
    // has not arrived yet is indistinguishable from no target at all. The
    // listen keeps it alive long enough to emit — without a subscriber it is
    // disposed mid-load and the future never completes.
    container.listen(targetHistoryProvider, (_, _) {});
    await container.read(targetHistoryProvider.future);

    final target = container.read(targetForDayProvider('2026-09-14'))!;
    expect(target.shifted, isFalse);
    expect(target.carbG, 225);
  });

  test('no training at all leaves it alone', () async {
    final container = _container(
      shiftPct: 15,
      weekdays: const {},
      trainingToday: false,
    );
    addTearDown(container.dispose);
    // A StreamProvider read synchronously is still loading, and a target that
    // has not arrived yet is indistinguishable from no target at all. The
    // listen keeps it alive long enough to emit — without a subscriber it is
    // disposed mid-load and the future never completes.
    container.listen(targetHistoryProvider, (_, _) {});
    await container.read(targetHistoryProvider.future);

    final target = container.read(targetForDayProvider('2026-09-14'))!;
    expect(target.shifted, isFalse);
  });

  test('no target set at all is still null', () async {
    final container = ProviderContainer(
      overrides: [
        targetHistoryProvider.overrideWith((ref) => Stream.value(const [])),
        recentSessionsProvider.overrideWith((ref) => Stream.value(const [])),
        trainingRhythmProvider.overrideWithValue(
          const TrainingRhythm(weekdays: {1, 3, 5}, trainingToday: true),
        ),
      ],
    );
    addTearDown(container.dispose);
    // A StreamProvider read synchronously is still loading, and a target that
    // has not arrived yet is indistinguishable from no target at all. The
    // listen keeps it alive long enough to emit — without a subscriber it is
    // disposed mid-load and the future never completes.
    container.listen(targetHistoryProvider, (_, _) {});
    await container.read(targetHistoryProvider.future);

    expect(container.read(targetForDayProvider('2026-09-14')), isNull);
  });

  test('a day before the target existed gets no target', () async {
    final container = _container(
      shiftPct: 15,
      weekdays: {1, 3, 5},
      trainingToday: true,
    );
    addTearDown(container.dispose);
    // A StreamProvider read synchronously is still loading, and a target that
    // has not arrived yet is indistinguishable from no target at all. The
    // listen keeps it alive long enough to emit — without a subscriber it is
    // disposed mid-load and the future never completes.
    container.listen(targetHistoryProvider, (_, _) {});
    await container.read(targetHistoryProvider.future);

    expect(container.read(targetForDayProvider('2026-08-30')), isNull);
  });
}

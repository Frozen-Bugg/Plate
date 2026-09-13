import 'package:engine/engine.dart';
import 'package:test/test.dart';

/// Moving carbohydrate onto training days without adding any.
///
/// The property that matters is the weekly total: this is a distribution, not
/// extra food, and a shift that quietly adds a few hundred calories a week
/// would show up as a stalled cut nobody could explain.

/// A target that adds up: 174 x 4 + 225 x 4 + 65 x 9 = 2181.
///
/// It has to, because one of the tests below asserts that a shifted target
/// still does, and a fixture that was 99 kcal out on its own would have failed
/// that for a reason that had nothing to do with shifting.
MacroTarget base({int carbG = 225}) => MacroTarget(
      kcal: 2181,
      proteinG: 174,
      fatG: 65,
      carbG: carbG,
      flooredAtBmr: false,
    );

/// What a week actually adds up to under a shift.
({int carbG, int kcal}) week({
  required MacroTarget target,
  required int shiftPct,
  required int trainingDays,
}) {
  final training = shiftCarbs(
    target: target,
    shiftPct: shiftPct,
    isTrainingDay: true,
    trainingDaysPerWeek: trainingDays,
  );
  final rest = shiftCarbs(
    target: target,
    shiftPct: shiftPct,
    isTrainingDay: false,
    trainingDaysPerWeek: trainingDays,
  );
  final restDays = 7 - trainingDays;
  return (
    carbG: training.carbG * trainingDays + rest.carbG * restDays,
    kcal: training.kcal * trainingDays + rest.kcal * restDays,
  );
}

void main() {
  test('the week adds up to exactly what it did before', () {
    for (final days in [1, 2, 3, 4, 5, 6]) {
      for (final pct in [10, 15, 25, 50]) {
        final shifted = week(target: base(), shiftPct: pct, trainingDays: days);
        // Rounding to whole grams moves it a little; a few grams across seven
        // days is a rounding error, a few hundred is a bug.
        expect(
          shifted.carbG,
          closeTo(225 * 7, 7),
          reason: '$pct% over $days training days',
        );
        expect(shifted.kcal, closeTo(2181 * 7, 30));
      }
    }
  });

  test('a training day gets more and a rest day gets less', () {
    final training = shiftCarbs(
      target: base(),
      shiftPct: 15,
      isTrainingDay: true,
      trainingDaysPerWeek: 4,
    );
    final rest = shiftCarbs(
      target: base(),
      shiftPct: 15,
      isTrainingDay: false,
      trainingDaysPerWeek: 4,
    );

    // Three rest days give up 33.75 g each; 101 g split across four sessions.
    expect(rest.carbG, 191);
    expect(training.carbG, closeTo(250, 1));
    expect(training.kcal, greaterThan(rest.kcal));
  });

  test('only carbohydrate moves', () {
    final training = shiftCarbs(
      target: base(),
      shiftPct: 20,
      isTrainingDay: true,
      trainingDaysPerWeek: 3,
    );
    expect(training.proteinG, 174);
    expect(training.fatG, 65);
  });

  test('the calories follow the carbohydrate', () {
    final training = shiftCarbs(
      target: base(),
      shiftPct: 15,
      isTrainingDay: true,
      trainingDaysPerWeek: 4,
    );
    // A target whose macros no longer add up to its calories is worse than no
    // shift at all.
    expect(training.kcalFromMacros, closeTo(training.kcal, 3));
  });

  test('nothing to redistribute leaves the target alone', () {
    final target = base();
    for (final (why, result) in [
      ('no shift asked for',
          shiftCarbs(target: target, shiftPct: 0, isTrainingDay: true, trainingDaysPerWeek: 4)),
      // Seven sessions: no rest day to borrow against, and inventing the food
      // would be adding rather than moving.
      ('no rest days to borrow from',
          shiftCarbs(target: target, shiftPct: 15, isTrainingDay: true, trainingDaysPerWeek: 7)),
      ('no training days to move onto',
          shiftCarbs(target: target, shiftPct: 15, isTrainingDay: false, trainingDaysPerWeek: 0)),
    ]) {
      expect(result.carbG, target.carbG, reason: why);
      expect(result.kcal, target.kcal, reason: why);
    }
  });

  test('a target with no carbohydrate in it has none to move', () {
    // A very small person on a large deficit; dailyTarget reports zero rather
    // than a negative, and there is nothing here to redistribute.
    final none = base(carbG: 0);
    final shifted = shiftCarbs(
      target: none,
      shiftPct: 15,
      isTrainingDay: true,
      trainingDaysPerWeek: 4,
    );
    expect(shifted.carbG, 0);
    expect(shifted.kcal, none.kcal);
  });

  test('an absurd shift is clamped rather than obeyed', () {
    // The column allows 0–50 and the engine should not depend on that holding.
    final rest = shiftCarbs(
      target: base(),
      shiftPct: 400,
      isTrainingDay: false,
      trainingDaysPerWeek: 4,
    );
    expect(rest.carbG, 113);
    expect(rest.carbG, greaterThanOrEqualTo(0));
  });

  test('the floored-at-BMR flag survives the shift', () {
    final floored = MacroTarget(
      kcal: 1600,
      proteinG: 150,
      fatG: 55,
      carbG: 100,
      flooredAtBmr: true,
    );
    final shifted = shiftCarbs(
      target: floored,
      shiftPct: 15,
      isTrainingDay: false,
      trainingDaysPerWeek: 4,
    );
    // A rest day under a shift drops below the floor the flag was raised for,
    // which is exactly when the UI needs to still be saying so.
    expect(shifted.flooredAtBmr, isTrue);
  });
}

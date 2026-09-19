import 'package:engine/engine.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/coach/proposal_keeper.dart';

/// The wiring around `engine.proposeCalorieChange`. The arithmetic itself is
/// tested in packages/engine — see `carb_shift_wiring_test.dart` for the same
/// reasoning applied to the training-day carb shift.

DateTime _day(int n) => DateTime.utc(2026, 9, n);

/// A trend moving at a steady [percentPerWeek], 40 days of it — long enough
/// for `proposeCalorieChange`'s 14-day window either way.
List<engine.TrendPoint> _movingAt(double percentPerWeek, {double start = 80}) {
  final perDay = start * percentPerWeek / 100 / 7;
  return engine.weightTrend([
    for (var i = 0; i < 40; i++)
      engine.WeighIn(
        date: _day(1).add(Duration(days: i)),
        weightKg: start + i * perDay,
      ),
  ]);
}

NutritionTarget _target({int kcal = 2400}) => NutritionTarget(
  id: 't',
  createdAt: _day(1),
  updatedAt: _day(1),
  userId: 'u',
  effectiveFrom: '2026-09-01',
  kcal: kcal,
  proteinG: 180,
  carbG: 220,
  fatG: 70,
  source: 'engine',
);

void main() {
  test('nothing due while the trend matches the phase', () {
    final built = buildTargetsProposal(
      trend: _movingAt(-0.75),
      phaseWire: 'cut',
      target: _target(),
    );
    expect(built, isNull);
  });

  test('proposes a cut when weight has stalled', () {
    final built = buildTargetsProposal(
      trend: _movingAt(0),
      phaseWire: 'cut',
      target: _target(kcal: 2400),
    );
    expect(built, isNotNull);
    expect(built!.payload['toKcal'], lessThan(2400));
    expect(built.rationale, contains('2400'));
  });

  test(
    'carries protein and fat over unchanged, and carbs absorb the delta',
    () {
      final built = buildTargetsProposal(
        trend: _movingAt(0),
        phaseWire: 'cut',
        target: _target(),
      )!;

      expect(built.payload['proteinG'], 180);
      expect(built.payload['fatG'], 70);
      final deltaKcal =
          (built.payload['toKcal'] as int) - (built.payload['fromKcal'] as int);
      final carbDelta = (built.payload['carbG'] as num) - 220;
      expect(carbDelta * engine.kcalPerGramCarb, closeTo(deltaKcal, 0.01));
    },
  );

  test('does not propose a cut that would land under BMR', () {
    // Stalled on a cut wants to go lower; a BMR right at the current target
    // leaves nowhere safe to cut to.
    final built = buildTargetsProposal(
      trend: _movingAt(0),
      phaseWire: 'cut',
      target: _target(kcal: 2400),
      bmr: 2400,
    );
    expect(built, isNull);
  });

  test('proposes normally when the floor is comfortably below the cut', () {
    final built = buildTargetsProposal(
      trend: _movingAt(0),
      phaseWire: 'cut',
      target: _target(kcal: 2400),
      bmr: 1500,
    );
    expect(built, isNotNull);
  });
}

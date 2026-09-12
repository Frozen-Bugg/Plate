import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:overload/features/train/exercises_repository.dart';

/// The app offers a set of equipment kinds; Postgres enforces one in a check
/// constraint. If they drift apart, the exercise is created happily on the
/// phone, syncs, and is refused — and the lifter finds out from a "Not saved"
/// chip some time later, with the movement gone.
///
/// Reading the constraint out of the migration keeps the two honest without
/// anyone having to remember.
void main() {
  test('every equipment kind the picker offers is one Postgres accepts', () {
    final sql =
        File('../supabase/migrations/20260912000000_schema_v1.sql').readAsStringSync();

    final match = RegExp(
      r'equipment\s+text\s+not\s+null\s+default\s+.+?'
      r'check\s*\(equipment\s+in\s*\(([^)]*)\)\)',
      dotAll: true,
    ).firstMatch(sql);
    expect(match, isNotNull, reason: 'the equipment check constraint moved');

    final allowed = RegExp("'([a-z_]+)'")
        .allMatches(match!.group(1)!)
        .map((m) => m.group(1)!)
        .toSet();

    expect(allowed, isNotEmpty);
    expect(equipmentKinds.toSet(), equals(allowed));
  });

  group('defaultLoadStep', () {
    test('gives each kind of equipment the jump it can actually make', () {
      // A barbell takes 1.25s a side, so 2.5 total; a dumbbell rack goes up in
      // 2s; a machine's pin usually moves in 5s.
      expect(defaultLoadStep('barbell'), 2.5);
      expect(defaultLoadStep('dumbbell'), 2.0);
      expect(defaultLoadStep('machine'), 5.0);
      expect(defaultLoadStep('cable'), 5.0);
    });

    test('bodyweight and bands move in the smallest step there is', () {
      // Added load on a dip belt, or the next band along. Never zero: the
      // engine adds one step to progress, and a step of nothing is a stall
      // that never resolves.
      expect(defaultLoadStep('bodyweight'), greaterThan(0));
      expect(defaultLoadStep('band'), greaterThan(0));
    });

    test('every offered kind has a positive step', () {
      for (final kind in equipmentKinds) {
        expect(defaultLoadStep(kind), greaterThan(0), reason: 'for $kind');
      }
    });

    test('an unknown kind falls back rather than returning zero', () {
      expect(defaultLoadStep('trapeze'), greaterThan(0));
    });
  });
}

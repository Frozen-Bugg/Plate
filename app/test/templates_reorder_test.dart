import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/app/theme.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/train/exercises_repository.dart';
import 'package:overload/features/train/templates_repository.dart';
import 'package:overload/features/train/templates_screen.dart';

import 'support/test_database.dart';

/// A template's exercises, reordered by dragging a handle, end to end
/// against a real (in-memory) database rather than a faked stream — see
/// test/support/test_database.dart for why that is a faithful stand-in.
///
/// `pumpAndSettle()` is deliberately not used. The screen watches a real
/// Drift stream over a real sqlite database, and that combination never
/// satisfies `hasScheduledFrame`'s idea of settled, so `pumpAndSettle` spins
/// forever. A bounded number of explicit pumps does not have that problem,
/// and it is what [_settle] does.
void main() {
  const userId = 'u-1';
  const benchId = 'bench';
  const squatId = 'squat';

  late TestDatabase db;
  late ExercisesRepository exercisesRepo;
  late TemplatesRepository templatesRepo;

  setUp(() async {
    db = TestDatabase();
    exercisesRepo = ExercisesRepository(db, userId);
    templatesRepo = TemplatesRepository(db, userId);

    // Seeded rows carry no owner, the same as the exercises the app ships
    // with — see exercises_repository.dart.
    for (final (id, name) in [
      (benchId, 'Bench Press'),
      (squatId, 'Back Squat'),
    ]) {
      await db
          .into(db.exercises)
          .insert(
            ExercisesCompanion.insert(
              id: Value(id),
              userId: const Value(null),
              name: name,
              equipment: const Value('barbell'),
            ),
          );
    }
  });

  tearDown(() => db.close());

  Widget app(Widget home) => ProviderScope(
    overrides: [
      exercisesRepositoryProvider.overrideWithValue(exercisesRepo),
      templatesRepositoryProvider.overrideWithValue(templatesRepo),
    ],
    child: MaterialApp(theme: buildTheme(Brightness.light), home: home),
  );

  Future<void> settle(WidgetTester tester, {int times = 8}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Tears the widget tree down inside the test body, rather than leaving it
  /// to `testWidgets`' own automatic teardown.
  ///
  /// The screen watches a real Drift `.watch()` stream, and disposing one
  /// schedules a zero-duration `Timer` internally (drift's
  /// `StreamQueryStore.markAsClosed`) to finish closing it. That timer only
  /// needs one more event-loop turn to fire and clear itself — but if
  /// nothing asks for that turn before the test function returns, Flutter's
  /// own teardown finds it still pending and fails the test over a timer
  /// that was never actually going to leak. Swapping in an empty tree and
  /// pumping once gives it that turn while still inside this function, where
  /// a delay is controlled rather than found out about via a flaky-looking
  /// timeout.
  Future<void> disposeCleanly(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // `pump()` with no argument only flushes microtasks — it does not call
    // `elapse()`, so a zero-duration Timer sits there un-fired no matter how
    // many times it is called. Passing an explicit duration, even a tiny
    // one, is what actually lets drift's cleanup timer run.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  testWidgets(
    'a template is built, dragged into a new order, and the database agrees',
    (tester) async {
      await tester.pumpWidget(app(const TemplatesScreen()));
      await settle(tester);

      // New template, named through the dialog.
      await tester.tap(find.byIcon(Icons.add));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'Push Day');
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(find.widgetWithText(AppBar, 'Push Day'), findsOneWidget);

      // Add Bench, then Squat, in that order.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Add exercise'));
      await settle(tester);
      await tester.tap(find.text('Bench Press'));
      await settle(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Add exercise'));
      await settle(tester);
      await tester.tap(find.text('Back Squat'));
      await settle(tester);

      expect(
        tester.getTopLeft(find.text('Bench Press')).dy,
        lessThan(tester.getTopLeft(find.text('Back Squat')).dy),
        reason: 'Bench was added first, so it starts on top',
      );

      // Drag Bench's handle down past Squat's row.
      final handle = find.byIcon(Icons.drag_handle).first;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 160));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      // The reorder write itself is fire-and-forget from the widget's side —
      // real, but not awaited by anything the test can see. Give it a few
      // more turns of the event loop to actually land before asking the
      // database what it thinks happened.
      await settle(tester);

      expect(
        tester.getTopLeft(find.text('Back Squat')).dy,
        lessThan(tester.getTopLeft(find.text('Bench Press')).dy),
        reason:
            'dragging Bench below Squat should have swapped them on '
            'screen',
      );

      // And in the database — the thing the drag is actually for. A one-shot
      // read rather than another `.watch()`: the screen above is still
      // mounted and already holds a live subscription to this exact query,
      // and joining that same stream late is not the same thing as asking
      // the table what it currently holds.
      final templateId =
          (await (db.select(db.templates)
                    ..where((t) => t.userId.equals(userId))
                    ..where((t) => t.deletedAt.isNull()))
                  .get())
              .single
              .id;
      final order =
          await (db.select(db.templateExercises)
                ..where((e) => e.templateId.equals(templateId))
                ..where((e) => e.deletedAt.isNull())
                ..orderBy([(e) => OrderingTerm.asc(e.position)]))
              .get();
      expect(
        order.map((e) => e.exerciseId),
        [squatId, benchId],
        reason: 'the write the drag triggers should match what is on screen',
      );

      await disposeCleanly(tester);
    },
  );
}

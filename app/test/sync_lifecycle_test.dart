import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/sync/sync_lifecycle.dart';

/// A short grace so the tests are quick. The policy is what is under test, not
/// the number.
const grace = Duration(milliseconds: 20);

/// Long enough for the grace timer to have fired.
Future<void> waitOut() => Future<void>.delayed(grace * 3);

void main() {
  late int connects;
  late int disconnects;
  late SyncLifecycle lifecycle;

  setUp(() {
    connects = 0;
    disconnects = 0;
    lifecycle = SyncLifecycle(
      connect: () async => connects++,
      disconnect: () async => disconnects++,
      grace: grace,
    );
  });

  tearDown(() => lifecycle.dispose());

  test('starts out believing the connection is up', () {
    expect(lifecycle.online, isTrue);
    expect(connects, 0, reason: 'the provider connects on sign-in, not here');
  });

  test('drops the connection once the app has been away long enough', () async {
    lifecycle.paused();
    expect(disconnects, 0, reason: 'not immediately');
    expect(lifecycle.closing, isTrue);

    await waitOut();
    expect(disconnects, 1);
    expect(lifecycle.online, isFalse);
  });

  test('a quick trip out and back costs nothing', () async {
    // Glancing at a notification, or the camera opening for a progress photo.
    // Tearing the connection down and rebuilding it would cost more than
    // holding it.
    lifecycle.paused();
    lifecycle.resumed();
    await waitOut();

    expect(disconnects, 0);
    expect(connects, 0);
    expect(lifecycle.online, isTrue);
  });

  test('reconnects when the app comes back after the grace period', () async {
    lifecycle.paused();
    await waitOut();
    expect(disconnects, 1);

    lifecycle.resumed();
    expect(connects, 1);
    expect(lifecycle.online, isTrue);
  });

  test('resuming while already connected does not reconnect', () async {
    lifecycle
      ..resumed()
      ..resumed();
    expect(connects, 0);
  });

  test('pausing twice schedules one disconnect', () async {
    lifecycle
      ..paused()
      ..paused();
    await waitOut();
    expect(disconnects, 1);
  });

  test('stays disconnected while the app stays away', () async {
    lifecycle.paused();
    await waitOut();
    lifecycle.paused();
    await waitOut();

    expect(disconnects, 1, reason: 'already down; nothing to do');
  });

  test('a disposed lifecycle does nothing further', () async {
    lifecycle.paused();
    lifecycle.dispose();
    await waitOut();

    expect(disconnects, 0);
    lifecycle.resumed();
    expect(connects, 0);
  });

  test('a connection that refuses to close is not fatal', () async {
    // The app works offline by design. A failed disconnect must not take the
    // isolate down with it, and the next resume tries again.
    final failing = SyncLifecycle(
      connect: () async => throw StateError('no'),
      disconnect: () async => throw StateError('no'),
      grace: grace,
    );
    addTearDown(failing.dispose);

    failing.paused();
    await waitOut();
    expect(failing.online, isFalse);

    failing.resumed();
    await waitOut();
    expect(failing.online, isTrue);
  });
}

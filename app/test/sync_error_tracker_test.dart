import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/sync/sync_error_tracker.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 12, 6, 0);
  final t1 = DateTime.utc(2026, 9, 12, 6, 5);
  final t2 = DateTime.utc(2026, 9, 12, 6, 10);

  test('no error is not an error', () {
    final tracker = SyncErrorTracker();
    expect(
      tracker.errorIsLive(error: null, lastSyncedAt: t0),
      isFalse,
    );
  });

  test('a new error is live', () {
    final tracker = SyncErrorTracker();
    expect(
      tracker.errorIsLive(error: 'connection closed', lastSyncedAt: t0),
      isTrue,
    );
  });

  test('an error stays live while nothing has synced since', () {
    final tracker = SyncErrorTracker();
    final error = Exception('connection closed');
    expect(tracker.errorIsLive(error: error, lastSyncedAt: t0), isTrue);
    // PowerSync re-emits the same sticky error with no new checkpoint.
    expect(tracker.errorIsLive(error: error, lastSyncedAt: t0), isTrue);
  });

  // The regression this class exists for: the reconnect blip after airplane
  // mode, where the upload succeeds but anyError is never cleared.
  test('a syncing-again database clears an error it recovered from', () {
    final tracker = SyncErrorTracker();
    final error = Exception('Connection closed before full header was received');
    expect(tracker.errorIsLive(error: error, lastSyncedAt: t0), isTrue);
    expect(tracker.errorIsLive(error: error, lastSyncedAt: t1), isFalse);
    // And it stays cleared as the same stale error keeps being reported.
    expect(tracker.errorIsLive(error: error, lastSyncedAt: t1), isFalse);
    expect(tracker.errorIsLive(error: error, lastSyncedAt: t2), isFalse);
  });

  test('a fresh failure after a recovery is live again', () {
    final tracker = SyncErrorTracker();
    final first = Exception('first');
    expect(tracker.errorIsLive(error: first, lastSyncedAt: t0), isTrue);
    expect(tracker.errorIsLive(error: first, lastSyncedAt: t1), isFalse);

    final second = Exception('second');
    expect(tracker.errorIsLive(error: second, lastSyncedAt: t1), isTrue);
    expect(tracker.errorIsLive(error: second, lastSyncedAt: t2), isFalse);
  });

  test('an error on a database that has never synced stays live', () {
    final tracker = SyncErrorTracker();
    final error = Exception('no connection yet');
    expect(tracker.errorIsLive(error: error, lastSyncedAt: null), isTrue);
    expect(tracker.errorIsLive(error: error, lastSyncedAt: null), isTrue);
  });

  test('the first sync of all clears an error raised before it', () {
    final tracker = SyncErrorTracker();
    final error = Exception('failed before the first checkpoint');
    expect(tracker.errorIsLive(error: error, lastSyncedAt: null), isTrue);
    expect(tracker.errorIsLive(error: error, lastSyncedAt: t0), isFalse);
  });

  test('a cleared error resets the tracker, so its return is live', () {
    final tracker = SyncErrorTracker();
    final error = Exception('flaky');
    expect(tracker.errorIsLive(error: error, lastSyncedAt: t0), isTrue);
    expect(tracker.errorIsLive(error: null, lastSyncedAt: t1), isFalse);
    expect(tracker.errorIsLive(error: error, lastSyncedAt: t1), isTrue);
  });
}

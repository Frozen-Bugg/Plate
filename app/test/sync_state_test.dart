import 'package:flutter_test/flutter_test.dart';
import 'package:overload/app/widgets/sync_status_chip.dart';

void main() {
  SyncState state({
    bool connected = true,
    bool connecting = false,
    bool uploading = false,
    bool downloading = false,
    bool? hasSynced = true,
    bool hasLiveError = false,
    bool hasRejections = false,
  }) =>
      SyncState.from(
        connected: connected,
        connecting: connecting,
        uploading: uploading,
        downloading: downloading,
        hasSynced: hasSynced,
        hasLiveError: hasLiveError,
        hasRejections: hasRejections,
      );

  test('synced when connected, idle and caught up', () {
    expect(state(), SyncState.synced);
  });

  test('offline beats errors, since failed requests are expected with no signal', () {
    expect(state(connected: false, hasLiveError: true), SyncState.offline);
  });

  test('connecting is shown while the connection is being set up', () {
    expect(state(connected: false, connecting: true), SyncState.connecting);
  });

  test('syncing while uploading, downloading or before the first full sync', () {
    expect(state(uploading: true), SyncState.syncing);
    expect(state(downloading: true), SyncState.syncing);
    expect(state(hasSynced: null), SyncState.syncing);
  });

  group('a rejected write', () {
    test('outranks a healthy sync', () {
      expect(state(hasRejections: true), SyncState.rejected);
    });

    test('outranks being offline, which resolves itself', () {
      // A dropped write does not come back when the signal does.
      expect(
        state(connected: false, hasRejections: true),
        SyncState.rejected,
      );
    });

    test('outranks a live error', () {
      expect(state(hasLiveError: true, hasRejections: true), SyncState.rejected);
    });

    test('outranks work still in flight', () {
      expect(state(uploading: true, hasRejections: true), SyncState.rejected);
      expect(state(connecting: true, hasRejections: true), SyncState.rejected);
    });
  });

  test('error only when connected', () {
    expect(state(hasLiveError: true), SyncState.error);
  });
}

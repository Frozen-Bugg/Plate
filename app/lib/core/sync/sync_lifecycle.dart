import 'dart:async';

import 'package:logging/logging.dart';

final _log = Logger('sync-lifecycle');

/// How long the app stays connected after it goes out of view.
///
/// Long enough to cover the ordinary interruptions — glancing at a
/// notification, switching to the camera for a progress photo, answering a
/// message between sets — because tearing the connection down and building it
/// back up costs more than holding it open for a minute. Short enough that a
/// phone in a pocket is not holding a socket open all afternoon.
const syncBackgroundGrace = Duration(minutes: 2);

/// Holds the sync connection open while the app is in use, and lets it go when
/// it is not.
///
/// PowerSync keeps a streaming connection to the service for as long as it is
/// connected, which is what makes a weigh-in on the phone appear on the web in
/// a second. In the foreground that is the whole point. In the background it is
/// a socket being kept alive, and a radio being woken, for data nobody is
/// looking at.
///
/// Nothing is lost by disconnecting. Writes queue locally and upload on the
/// next connect — the same path a workout logged in a basement gym already
/// takes, and the reason the app is local-first in the first place.
///
/// Deliberately ignorant of Flutter: it takes two callbacks and a clock so the
/// policy can be tested without a widget tree.
class SyncLifecycle {
  SyncLifecycle({
    required Future<void> Function() connect,
    required Future<void> Function() disconnect,
    this.grace = syncBackgroundGrace,
  })  : _connect = connect,
        _disconnect = disconnect;

  final Future<void> Function() _connect;
  final Future<void> Function() _disconnect;

  /// How long the app may be out of view before the connection is dropped.
  final Duration grace;

  Timer? _pending;
  var _online = true;
  var _disposed = false;

  /// Whether the connection is currently meant to be up.
  bool get online => _online;

  /// Whether a disconnect is counting down. Test seam.
  bool get closing => _pending != null;

  /// The app came back into view: cancel any countdown, and reconnect if the
  /// countdown already finished.
  void resumed() {
    if (_disposed) return;
    _pending?.cancel();
    _pending = null;
    if (_online) return;
    _online = true;
    unawaited(_guard(_connect, 'reconnect'));
  }

  /// The app went out of view. Starts the countdown rather than disconnecting,
  /// so a two-second trip to another app does not cost a reconnect.
  void paused() {
    if (_disposed || !_online || _pending != null) return;
    _pending = Timer(grace, () {
      _pending = null;
      if (_disposed || !_online) return;
      _online = false;
      unawaited(_guard(_disconnect, 'disconnect'));
    });
  }

  void dispose() {
    _disposed = true;
    _pending?.cancel();
    _pending = null;
  }

  /// A connection that cannot be brought up or down is not worth crashing over:
  /// the app works offline by design, and the next resume tries again.
  Future<void> _guard(Future<void> Function() action, String what) async {
    try {
      await action();
    } catch (e, stack) {
      _log.warning('Could not $what the sync connection', e, stack);
    }
  }
}

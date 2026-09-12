/// Tells a sync failure the connection is still stuck on from one it has
/// already recovered from.
///
/// PowerSync never clears `SyncStatus.anyError`: the last error stays on the
/// status long after a later checkpoint succeeds. Reading it as a live
/// condition pins the UI to "Sync error" forever, and coming back from
/// airplane mode reliably produces a blip ("Connection closed before full
/// header was received") as the socket re-establishes — so the app would
/// report failure for a sync that actually worked.
///
/// Errors carry no timestamp, but `SyncStatus.lastSyncedAt` advances on every
/// applied checkpoint. Remembering its value when an error first arrives is
/// enough: if the database has synced since, the error is history.
///
/// Stateful by necessity — each answer depends on the statuses before it — so
/// hold one instance per database and feed it every status in order. Calling
/// [errorIsLive] repeatedly with an unchanged status is safe and returns the
/// same answer.
class SyncErrorTracker {
  Object? _error;
  DateTime? _syncedAtWhenSeen;

  /// Whether [error] is a failure that has not been followed by a successful
  /// sync. Pass `SyncStatus.anyError` and `SyncStatus.lastSyncedAt`.
  bool errorIsLive({required Object? error, required DateTime? lastSyncedAt}) {
    if (error == null) {
      _error = null;
      _syncedAtWhenSeen = null;
      return false;
    }

    // A different error object means a fresh failure, whatever came before.
    if (!identical(error, _error)) {
      _error = error;
      _syncedAtWhenSeen = lastSyncedAt;
      return true;
    }

    // Still never synced, so nothing has disproved the error.
    if (lastSyncedAt == null) return true;
    // The first successful sync since the error arrived clears it.
    final seenAt = _syncedAtWhenSeen;
    if (seenAt == null) return false;
    return !lastSyncedAt.isAfter(seenAt);
  }
}

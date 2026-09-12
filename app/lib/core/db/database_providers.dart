import 'package:drift/drift.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../sync/supabase_connector.dart';
import '../sync/sync_error_tracker.dart';
import 'app_database.dart';
import 'powersync_schema.dart';

/// The on-device database. Connects to PowerSync while a user is signed in,
/// and wipes local data on sign-out.
final powerSyncProvider = FutureProvider<PowerSyncDatabase>((ref) async {
  final dir = await getApplicationSupportDirectory();
  final db = PowerSyncDatabase(
    schema: schema,
    path: p.join(dir.path, 'overload.db'),
    logger: Logger('powersync'),
  );
  await db.initialize();

  final supabase = Supabase.instance.client;
  SupabaseConnector? connector;

  Future<void> connect() {
    if (!AppConfig.syncConfigured) return Future.value();
    connector = SupabaseConnector(supabase);
    return db.connect(connector: connector!);
  }

  if (supabase.auth.currentSession != null) {
    await connect();
  }

  final subscription = supabase.auth.onAuthStateChange.listen((data) async {
    switch (data.event) {
      case AuthChangeEvent.signedIn:
        await connect();
      case AuthChangeEvent.signedOut:
        connector = null;
        await db.disconnectAndClear();
      case AuthChangeEvent.tokenRefreshed:
        await connector?.prefetchCredentials();
      default:
        break;
    }
  });

  ref.onDispose(() async {
    await subscription.cancel();
    await db.close();
  });
  return db;
});

/// Typed Drift queries over the PowerSync database.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(DatabaseConnection.delayed(Future(() async {
    final powerSync = await ref.read(powerSyncProvider.future);
    return SqliteAsyncDriftConnection(powerSync);
  })));
  ref.onDispose(db.close);
  return db;
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  final db = await ref.watch(powerSyncProvider.future);
  yield db.currentStatus;
  yield* db.statusStream;
});

/// Local writes not yet uploaded. Re-read whenever the sync status changes.
final pendingUploadsProvider = FutureProvider<int>((ref) async {
  ref.watch(syncStatusProvider);
  final db = await ref.watch(powerSyncProvider.future);
  return (await db.getUploadQueueStats()).count;
});

/// One tracker per database, so it sees every status in order.
final _syncErrorTrackerProvider = Provider<SyncErrorTracker>((ref) {
  ref.watch(powerSyncProvider);
  return SyncErrorTracker();
});

/// Whether sync is currently failing, as opposed to having failed at some
/// point in the past. `SyncStatus.anyError` only ever answers the second
/// question — see [SyncErrorTracker].
final syncHasLiveErrorProvider = Provider<bool>((ref) {
  final status = ref.watch(syncStatusProvider).value;
  if (status == null) return false;
  return ref.watch(_syncErrorTrackerProvider).errorIsLive(
        error: status.anyError,
        lastSyncedAt: status.lastSyncedAt,
      );
});

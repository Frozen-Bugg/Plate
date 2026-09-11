import 'package:logging/logging.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import 'upload_mapping.dart';

final _log = Logger('sync');

/// Postgres error classes that retrying cannot fix. Uploads failing with these
/// are discarded so they don't block the queue forever.
final _fatalResponseCodes = [
  RegExp(r'^22...$'), // data exception, e.g. type mismatch
  RegExp(r'^23...$'), // integrity constraint: not null, foreign key, check
  RegExp(r'^42501$'), // insufficient privilege, i.e. a row-level security violation
];

/// Authenticates PowerSync with the Supabase session and uploads local writes
/// to Postgres through PostgREST (so RLS applies to every write).
class SupabaseConnector extends PowerSyncBackendConnector {
  SupabaseConnector(this._supabase);

  final SupabaseClient _supabase;
  Future<void>? _refreshFuture;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    await _refreshFuture;
    final session = _supabase.auth.currentSession;
    if (session == null) return null;
    return PowerSyncCredentials(
      endpoint: AppConfig.powersyncUrl,
      token: session.accessToken,
      userId: session.user.id,
      expiresAt: session.expiresAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(session.expiresAt! * 1000),
    );
  }

  @override
  void invalidateCredentials() {
    // PowerSync rejected the token, e.g. after a long time offline. Refresh
    // now instead of waiting for Supabase's own timer; errors surface as an
    // expired token on the next attempt.
    _refreshFuture = _supabase.auth
        .refreshSession()
        .timeout(const Duration(seconds: 5))
        .then((_) => null, onError: (_) => null);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final transaction = await database.getNextCrudTransaction();
    if (transaction == null) return;

    CrudEntry? lastOp;
    try {
      for (final op in transaction.crud) {
        lastOp = op;
        final table = _supabase.rest.from(op.table);
        switch (op.op) {
          case UpdateType.put:
            await table.upsert({
              ...toSupabaseRow(op.table, op.opData ?? const {}),
              'id': op.id,
            });
          case UpdateType.patch:
            await table
                .update(toSupabaseRow(op.table, op.opData ?? const {}))
                .eq('id', op.id);
          case UpdateType.delete:
            await table.delete().eq('id', op.id);
        }
      }
      await transaction.complete();
    } on PostgrestException catch (e) {
      final code = e.code;
      if (code != null && _fatalResponseCodes.any((re) => re.hasMatch(code))) {
        // A bug in the app, not a network problem. Log loudly and move on so
        // the rest of the queue can sync.
        _log.severe('Discarding upload that Postgres rejected: $lastOp', e);
        await transaction.complete();
      } else {
        rethrow; // Retryable: PowerSync calls uploadData again after a delay.
      }
    }
  }
}

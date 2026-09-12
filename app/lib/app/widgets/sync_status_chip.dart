import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:powersync/powersync.dart';

import '../../core/config/app_config.dart';
import '../../core/db/database_providers.dart';
import '../../core/sync/sync_error_tracker.dart';
import '../../core/sync/sync_rejections.dart';
import '../router.dart';
import '../theme.dart';

enum SyncState {
  /// No PowerSync instance configured: everything stays on this phone.
  localOnly('Local only'),
  starting('Starting'),
  offline('Offline'),
  connecting('Connecting'),
  syncing('Syncing'),
  synced('Synced'),
  error('Sync error'),

  /// Postgres refused a write and it was dropped from the queue.
  rejected('Not saved');

  const SyncState(this.label);
  final String label;

  /// Offline wins over errors: a failed request while offline is expected,
  /// and PowerSync retries on its own once the connection is back.
  ///
  /// A rejection wins over everything. Offline and error are states the app
  /// gets itself out of; a rejected write is already gone, and no amount of
  /// waiting brings it back.
  ///
  /// [hasLiveError] must describe a failure that has not been followed by a
  /// successful sync, not merely the presence of `SyncStatus.anyError` — that
  /// field is never cleared. See [SyncErrorTracker].
  static SyncState from({
    required bool connected,
    required bool connecting,
    required bool uploading,
    required bool downloading,
    required bool? hasSynced,
    required bool hasLiveError,
    bool hasRejections = false,
  }) {
    if (hasRejections) return SyncState.rejected;
    if (connecting) return SyncState.connecting;
    if (!connected) return SyncState.offline;
    if (hasLiveError) return SyncState.error;
    if (uploading || downloading || hasSynced != true) return SyncState.syncing;
    return SyncState.synced;
  }

  static SyncState of(
    SyncStatus? status, {
    required bool hasLiveError,
    bool hasRejections = false,
  }) =>
      !AppConfig.syncConfigured
      ? SyncState.localOnly
      : status == null
      ? SyncState.starting
      : SyncState.from(
          connected: status.connected,
          connecting: status.connecting,
          uploading: status.uploading,
          downloading: status.downloading,
          hasSynced: status.hasSynced,
          hasLiveError: hasLiveError,
          hasRejections: hasRejections,
        );
}

/// Compact sync indicator for the app bar. Tapping it opens Settings, which
/// shows the details.
class SyncStatusChip extends ConsumerWidget {
  const SyncStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = SyncState.of(
      ref.watch(syncStatusProvider).value,
      hasLiveError: ref.watch(syncHasLiveErrorProvider),
      hasRejections:
          (ref.watch(outstandingRejectionsProvider).value ?? const []).isNotEmpty,
    );
    final pillars = PillarColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final dot = switch (state) {
      SyncState.synced => pillars.fuel,
      SyncState.syncing || SyncState.connecting => pillars.move,
      SyncState.error || SyncState.rejected => scheme.error,
      SyncState.offline || SyncState.starting || SyncState.localOnly =>
        scheme.outline,
    };

    return Semantics(
      button: true,
      label: 'Sync status: ${state.label}',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.push(Routes.settings),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                state.label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

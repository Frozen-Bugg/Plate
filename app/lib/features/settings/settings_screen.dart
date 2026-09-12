import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/sync_status_chip.dart';
import '../../core/auth/auth_service.dart';
import '../../core/config/app_config.dart';
import '../../core/db/database_providers.dart';
import '../../core/format.dart';
import '../../core/profile/profile_repository.dart';
import '../body/health_connect_tile.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final pending = ref.read(pendingUploadsProvider).value ?? 0;
    if (pending > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sign out with unsynced changes?'),
          content: Text(
            '$pending ${pending == 1 ? 'change hasn\'t' : 'changes haven\'t'} '
            'synced yet. Signing out deletes ${pending == 1 ? 'it' : 'them'} '
            'from this phone. Connect to the internet first to keep them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sign out anyway'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await ref.read(authServiceProvider).signOut();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final status = ref.watch(syncStatusProvider).value;
    final pending = ref.watch(pendingUploadsProvider).value;
    final hasLiveError = ref.watch(syncHasLiveErrorProvider);
    final state = SyncState.of(status, hasLiveError: hasLiveError);
    final text = Theme.of(context).textTheme;
    final provider = user?.appMetadata['provider'] as String?;

    Widget label(String value) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
          child: Text(
            value.toUpperCase(),
            style: text.labelSmall?.copyWith(
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          label('Account'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(user?.email ?? 'Signed in'),
            subtitle: provider == null ? null : Text('Signed in with $provider'),
          ),
          label('Goal'),
          const _PhasePicker(),
          label('Health'),
          const HealthConnectTile(),
          label('Sync'),
          ListTile(
            leading: const Icon(Icons.sync),
            title: Text(state.label),
            subtitle: Text(
              switch ((AppConfig.syncConfigured, status?.lastSyncedAt)) {
                (false, _) =>
                  'No PowerSync instance yet, so workouts stay on this phone',
                (_, final synced?) => 'Last synced ${formatAgo(synced)}',
                _ => 'Not synced yet on this phone',
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('Waiting to upload'),
            trailing: Text(
              pending == null ? '–' : '$pending',
              style: text.titleMedium,
            ),
          ),
          // Only while it still stands: a recovered-from error would otherwise
          // sit here indefinitely, reporting a failure that has since synced.
          if (status?.anyError case final error? when hasLiveError)
            ListTile(
              leading: const Icon(Icons.error_outline),
              title: const Text('Sync error'),
              subtitle: Text('$error'),
            ),
          const SizedBox(height: 24),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () => _signOut(context, ref),
          ),
        ],
      ),
    );
  }
}

/// Cut, maintain or lean bulk.
///
/// This is the only thing that tells the engine which way the scale is supposed
/// to move, so it decides whether a steady loss reads as progress or as a
/// problem. Phase 3 hangs calorie targets off the same choice.
class _PhasePicker extends ConsumerWidget {
  const _PhasePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final current = ref.watch(weightPhaseProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<engine.WeightPhase>(
            segments: const [
              ButtonSegment(
                value: engine.WeightPhase.cut,
                label: Text('Cut'),
              ),
              ButtonSegment(
                value: engine.WeightPhase.maintain,
                label: Text('Maintain'),
              ),
              ButtonSegment(
                value: engine.WeightPhase.bulk,
                label: Text('Lean bulk'),
              ),
            ],
            selected: {current},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => ref
                .read(profileRepositoryProvider)
                .setPhase(selection.first),
          ),
          const SizedBox(height: 8),
          Text(
            switch (current) {
              engine.WeightPhase.cut =>
                'Losing 0.5–1% of bodyweight a week. Holding your loads counts '
                    'as a win.',
              engine.WeightPhase.maintain =>
                'Holding within ±0.25% a week. Normal progression.',
              engine.WeightPhase.bulk =>
                'Gaining 0.25–0.5% a week. Faster than that is mostly fat.',
            },
            style: text.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}

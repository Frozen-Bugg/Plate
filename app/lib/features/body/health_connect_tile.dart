import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'health_import.dart';

/// Asks for Health Connect permissions and pulls the last fortnight in.
///
/// Always driven by a tap. Android will not show the permission sheet for a
/// background request, and an app that asks on first launch — before it has
/// shown anyone why it wants their sleep — is an app that gets refused once and
/// never asked again.
Future<void> connectHealth(BuildContext context, WidgetRef ref) async {
  final importer = ref.read(healthImporterProvider);
  final messenger = ScaffoldMessenger.of(context);

  if (!await importer.isAvailable()) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Health Connect is not installed on this phone'),
      ),
    );
    return;
  }

  if (!await importer.hasPermissions()) {
    final granted = await importer.requestPermissions();
    if (!granted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Health Connect access was not granted')),
      );
      return;
    }
  }

  final result = await importer.import();
  ref.invalidate(healthPermittedProvider);

  messenger.showSnackBar(
    SnackBar(
      content: Text(switch (result) {
        HealthImportResult.imported => 'Health data imported',
        HealthImportResult.unavailable =>
          'Health Connect is not installed on this phone',
        HealthImportResult.denied => 'Health Connect access was not granted',
        HealthImportResult.failed => 'Could not read from Health Connect',
      }),
    ),
  );
}

/// The Settings entry: what the connection is doing, and a way to change it.
class HealthConnectTile extends ConsumerWidget {
  const HealthConnectTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(healthAvailableProvider).value;
    final permitted = ref.watch(healthPermittedProvider).value ?? false;

    return ListTile(
      leading: const Icon(Icons.favorite_border),
      title: const Text('Health Connect'),
      subtitle: Text(switch ((available, permitted)) {
        (false, _) => 'Not installed on this phone',
        (null, _) => 'Checking…',
        (true, true) => 'Steps, sleep and heart rate are coming in',
        (true, false) => 'Not connected — steps and sleep stay empty',
      }),
      trailing: available == true && !permitted
          ? const Icon(Icons.chevron_right)
          : null,
      onTap: available == true ? () => connectHealth(context, ref) : null,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router.dart';
import 'sync_status_chip.dart';

/// Scaffold for a top-level tab: title, sync status and a Settings button.
class TabScaffold extends StatelessWidget {
  const TabScaffold({super.key, required this.title, required this.body});

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          const SyncStatusChip(),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(Routes.settings),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: body,
    );
  }
}

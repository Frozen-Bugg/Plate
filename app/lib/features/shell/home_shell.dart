import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/profile/profile_repository.dart';
import '../body/health_import.dart';
import '../body/photos_repository.dart';
import '../body/rollup_repository.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Both of these belong to the signed-in session rather than to any one
    // tab. Watched from a screen, they would stop the moment that screen was
    // not mounted — a weigh-in logged from Progress would leave daily_rollup
    // stale until Today happened to be visited again.
    //
    // Neither is awaited: nothing here waits for them, and their results reach
    // the screens through the database streams.
    ref.watch(healthAutoImportProvider);
    ref.watch(pendingPhotoUploadProvider);
    ref.watch(profileKeeperProvider);
    ref.watch(rollupKeeperProvider);

    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        // Tapping the current tab again pops it back to its root.
        onDestinationSelected: (index) =>
            shell.goBranch(index, initialLocation: index == shell.currentIndex),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.wb_sunny_outlined),
            selectedIcon: Icon(Icons.wb_sunny),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.fitness_center_outlined),
            selectedIcon: Icon(Icons.fitness_center),
            label: 'Train',
          ),
          NavigationDestination(
            icon: Icon(Icons.restaurant_outlined),
            selectedIcon: Icon(Icons.restaurant),
            label: 'Fuel',
          ),
          NavigationDestination(
            icon: Icon(Icons.show_chart_outlined),
            selectedIcon: Icon(Icons.show_chart),
            label: 'Progress',
          ),
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: 'Coach',
          ),
        ],
      ),
    );
  }
}

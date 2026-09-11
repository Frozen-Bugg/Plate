import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/sign_in_screen.dart';
import '../features/coach/coach_screen.dart';
import '../features/fuel/fuel_screen.dart';
import '../features/progress/progress_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/home_shell.dart';
import '../features/today/today_screen.dart';
import '../features/train/train_screen.dart';

abstract final class Routes {
  static const signIn = '/sign-in';
  static const today = '/today';
  static const train = '/train';
  static const fuel = '/fuel';
  static const progress = '/progress';
  static const coach = '/coach';
  static const settings = '/settings';
}

final routerProvider = Provider<GoRouter>((ref) {
  final auth = Supabase.instance.client.auth;
  final authChanges = _StreamListenable(auth.onAuthStateChange);

  final router = GoRouter(
    initialLocation: Routes.today,
    refreshListenable: authChanges,
    redirect: (context, state) {
      final signedIn = auth.currentSession != null;
      final onSignIn = state.matchedLocation == Routes.signIn;
      if (!signedIn) return onSignIn ? null : Routes.signIn;
      if (onSignIn) return Routes.today;
      return null;
    },
    routes: [
      GoRoute(path: Routes.signIn, builder: (_, _) => const SignInScreen()),
      GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => HomeShell(shell: shell),
        branches: [
          _branch(Routes.today, const TodayScreen()),
          _branch(Routes.train, const TrainScreen()),
          _branch(Routes.fuel, const FuelScreen()),
          _branch(Routes.progress, const ProgressScreen()),
          _branch(Routes.coach, const CoachScreen()),
        ],
      ),
    ],
  );

  ref.onDispose(() {
    router.dispose();
    authChanges.dispose();
  });
  return router;
});

StatefulShellBranch _branch(String path, Widget screen) => StatefulShellBranch(
      routes: [GoRoute(path: path, builder: (_, _) => screen)],
    );

/// Re-runs the router's redirect whenever the auth state changes.
class _StreamListenable extends ChangeNotifier {
  _StreamListenable(Stream<Object?> stream) {
    _subscription = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<Object?> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

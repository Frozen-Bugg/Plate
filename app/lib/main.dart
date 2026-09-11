import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/router.dart';
import 'app/theme.dart';
import 'core/config/app_config.dart';
import 'core/db/database_providers.dart';
import 'features/setup/setup_required_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    final error = record.error == null ? '' : ' — ${record.error}';
    debugPrint('[${record.loggerName}] ${record.level.name}: ${record.message}$error');
  });

  final missing = AppConfig.missingRequired;
  if (missing.isNotEmpty) {
    runApp(SetupRequiredApp(missingKeys: missing));
    return;
  }

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabasePublishableKey,
  );
  runApp(const ProviderScope(child: OverloadApp()));
}

class OverloadApp extends ConsumerWidget {
  const OverloadApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Open the local database and start syncing as soon as the app starts.
    ref.listen(powerSyncProvider, (_, _) {});

    return MaterialApp.router(
      title: 'Overload',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: ref.watch(routerProvider),
    );
  }
}

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Shown instead of the app when build-time config is missing, so a fresh
/// checkout explains itself instead of crashing.
class SetupRequiredApp extends StatelessWidget {
  const SetupRequiredApp({super.key, required this.missingKeys});

  final List<String> missingKeys;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: Builder(builder: (context) {
        final text = Theme.of(context).textTheme;
        return Scaffold(
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text('Overload needs its backend config', style: text.headlineMedium),
                const SizedBox(height: 12),
                Text('These values were not provided at build time:', style: text.bodyLarge),
                const SizedBox(height: 8),
                for (final key in missingKeys)
                  Text('•  $key', style: text.bodyLarge?.copyWith(fontFamily: 'monospace')),
                const SizedBox(height: 20),
                Text(
                  'Copy config/dev.example.json to config/dev.json, fill in your '
                  'Supabase and PowerSync values, then run:',
                  style: text.bodyLarge,
                ),
                const SizedBox(height: 8),
                const SelectableText(
                  'flutter run --dart-define-from-file=config/dev.json',
                  style: TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme.dart';
import '../../core/config/app_config.dart';
import '../../core/day.dart';

/// The note the coach writes without being asked — before a session, and after.
///
/// Three sentences at most, from the snapshot, no tools. It is decoration on a
/// screen somebody is trying to get past, so it never blocks: it appears when
/// it arrives, and when it cannot be written the screen looks exactly as it
/// did before. A workout must never wait on a model.
final _log = Logger('brief');

class BriefService {
  BriefService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Short on purpose. Past this the lifter has already started warming up and
  /// a brief is no longer a brief.
  static const _timeout = Duration(seconds: 25);

  /// Returns the note, or null when there is not one worth showing.
  ///
  /// Null rather than throwing: every failure here — offline, no balance, no
  /// key, a slow cold start — has the same right answer, which is to show
  /// nothing and let the lifter train.
  Future<String?> write({required String kind, String? justDid}) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) {
      _log.info('No $kind: signed out');
      return null;
    }

    _log.info('Asking for a $kind');
    try {
      final response = await _client
          .post(
            Uri.parse('${AppConfig.supabaseUrl}/functions/v1/coach/brief'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'kind': kind,
              'today': dayKey(),
              'justDid': ?justDid,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        // Nothing on screen, but never nothing anywhere. A note that silently
        // stops appearing is indistinguishable from a coach with nothing to
        // say, and that is the whole reason this project records what it drops.
        _log.info('No $kind: ${response.statusCode} ${response.body}');
        return null;
      }
      final text =
          (jsonDecode(response.body) as Map<String, dynamic>)['text'] as String?;
      if (text == null || text.trim().isEmpty) {
        // The last silent path, and the one that actually bit: a 200 carrying
        // nothing looks identical from here to a coach with nothing to say.
        _log.info('No $kind: the coach answered with nothing');
        return null;
      }
      return text.trim();
    } catch (e) {
      _log.info('No $kind: $e');
      return null;
    }
  }
}

final briefServiceProvider = Provider<BriefService>((ref) => BriefService());

/// The brief for the session about to start.
///
/// Keyed by day so it is written once and then cached: opening the Train tab
/// four times in a morning should not cost four model calls.
final preWorkoutBriefProvider = FutureProvider.family<String?, String>(
  (ref, day) => ref.watch(briefServiceProvider).write(kind: 'brief'),
);

/// Shows a brief, or nothing at all.
class BriefCard extends ConsumerWidget {
  const BriefCard({super.key, required this.day});

  final String day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brief = ref.watch(preWorkoutBriefProvider(day)).value;
    if (brief == null) return const SizedBox.shrink();
    return _Note(text: brief, label: 'BEFORE YOU START');
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.label});

  final String text;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = PillarColors.of(context).coach;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.forum_outlined, size: 14, color: accent),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: accent, letterSpacing: 1.2),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(text, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// The note after a session, shown once when it finishes.
///
/// A dialog rather than a card: the session it is about has just disappeared
/// off the screen, and a card on the Train tab would be a note about nothing.
Future<void> showDebrief(
  BuildContext context,
  WidgetRef ref, {
  required String justDid,
}) async {
  final text = await ref.read(briefServiceProvider).write(
        kind: 'debrief',
        justDid: justDid,
      );
  if (text == null || !context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.forum_outlined, color: PillarColors.of(context).coach),
      title: const Text('That session'),
      content: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

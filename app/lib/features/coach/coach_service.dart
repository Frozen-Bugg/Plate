import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_config.dart';
import '../../core/day.dart';

/// Something the coach sent back while answering.
sealed class CoachEvent {
  const CoachEvent();
}

/// A piece of the answer, as it is written.
class CoachDelta extends CoachEvent {
  const CoachDelta(this.text);
  final String text;
}

/// The finished answer, with what was looked at and what it cost.
class CoachDone extends CoachEvent {
  const CoachDone({
    required this.text,
    required this.chips,
    required this.model,
    required this.stop,
    required this.inputTokens,
    required this.outputTokens,
  });

  final String text;
  final List<CoachChip> chips;
  final String model;

  /// 'end', 'steps', 'length', 'refusal' or 'aborted'. Anything but 'end' means
  /// the answer is incomplete, and the screen says so rather than presenting it
  /// as final.
  final String stop;
  final int inputTokens;
  final int outputTokens;
}

/// The turn failed. Shown, never swallowed — the same rule the sync path
/// follows, and for the same reason.
class CoachFailed extends CoachEvent {
  const CoachFailed(this.message);
  final String message;
}

/// One thing the coach looked at, rendered as a chip under the answer.
class CoachChip {
  const CoachChip({required this.tool, required this.summary, required this.ok});

  final String tool;
  final String summary;
  final bool ok;

  factory CoachChip.fromJson(Map<String, dynamic> json) => CoachChip(
        tool: json['tool'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        ok: json['ok'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() =>
      {'tool': tool, 'summary': summary, 'ok': ok};
}

/// Talks to the Coach API.
///
/// Streams rather than waiting: a coach that reads six weeks of sessions before
/// it says anything looks broken for ten seconds, and watching the answer being
/// written is most of what makes the wait tolerable.
class CoachService {
  CoachService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Long, but not unbounded. The loop may run up to twelve tool steps, and the
  /// only thing worse than a slow answer is a request that hangs forever.
  static const _timeout = Duration(seconds: 120);

  Uri get _endpoint =>
      Uri.parse('${AppConfig.supabaseUrl}/functions/v1/coach');

  /// Asks a question and yields the answer as it arrives.
  Stream<CoachEvent> ask({
    required String message,
    required List<({String role, String text})> history,
    String? accessToken,
  }) async* {
    final token = accessToken ??
        Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) {
      yield const CoachFailed('You are signed out.');
      return;
    }

    final request = http.Request('POST', _endpoint)
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'message': message,
        'history': [
          for (final turn in history) {'role': turn.role, 'text': turn.text},
        ],
        // The day boundary is the lifter's, not the server's.
        'today': dayKey(),
      });

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_timeout);
    } catch (e) {
      yield CoachFailed(_offline(e));
      return;
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString().catchError((_) => '');
      yield CoachFailed(_explain(response.statusCode, body));
      return;
    }

    var sawAny = false;
    try {
      await for (final event in _events(response.stream)) {
        sawAny = true;
        yield event;
      }
    } catch (e) {
      yield CoachFailed(_offline(e));
      return;
    }

    // A 200 that carried nothing. The function died before it could say so, or
    // the runtime cut the stream — either way the turn has to report it rather
    // than leave an empty bubble, which is the silent-discard failure this
    // codebase already has rules about.
    if (!sawAny) {
      yield CoachFailed(
        'The coach accepted the question (HTTP ${response.statusCode}) but '
        'sent nothing back. Check the function logs in the Supabase dashboard.',
      );
    }
  }

  /// Parses the SSE stream into events.
  ///
  /// Frames do not arrive on message boundaries, so the buffer is kept across
  /// chunks — the same trap the server-side reader has, and the reason half an
  /// answer goes missing whenever it gets long.
  Stream<CoachEvent> _events(http.ByteStream bytes) async* {
    var buffer = '';

    await for (final chunk in bytes.transform(utf8.decoder)) {
      buffer += chunk;

      var split = buffer.indexOf('\n\n');
      while (split != -1) {
        final frame = buffer.substring(0, split);
        buffer = buffer.substring(split + 2);

        final event = _parse(frame);
        if (event != null) yield event;

        split = buffer.indexOf('\n\n');
      }
    }

    // The last event need not end with a blank line. Dropping it loses the
    // `done` frame — the whole answer, its chips and its usage — and the turn
    // then looks like a silent success.
    if (buffer.trim().isNotEmpty) {
      final event = _parse(buffer);
      if (event != null) yield event;
    }
  }

  CoachEvent? _parse(String frame) {
    String? name;
    final data = StringBuffer();

    for (final line in frame.split('\n')) {
      if (line.startsWith('event:')) name = line.substring(6).trim();
      if (line.startsWith('data:')) data.write(line.substring(5).trim());
    }
    if (name == null || data.isEmpty) return null;

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(data.toString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    switch (name) {
      case 'delta':
        return CoachDelta(json['text'] as String? ?? '');
      case 'done':
        final usage = (json['usage'] as Map<String, dynamic>?) ?? const {};
        return CoachDone(
          text: json['text'] as String? ?? '',
          chips: [
            for (final chip in (json['chips'] as List<dynamic>? ?? const []))
              CoachChip.fromJson((chip as Map).cast<String, dynamic>()),
          ],
          model: json['model'] as String? ?? '',
          stop: json['stop'] as String? ?? 'end',
          inputTokens: (usage['inputTokens'] as num?)?.toInt() ?? 0,
          outputTokens: (usage['outputTokens'] as num?)?.toInt() ?? 0,
        );
      case 'failed':
        return CoachFailed(json['message'] as String? ?? 'Something went wrong.');
      default:
        return null;
    }
  }

  /// Turns an HTTP status into something worth reading.
  ///
  /// 503 is the one that matters: it is what the function returns when a key is
  /// missing or the training-tier guard refuses, and its message is the
  /// one-line fix. Passing it through beats "something went wrong".
  static String _explain(int status, String body) {
    final detail = _detailOf(body);
    return switch (status) {
      401 => 'Your session expired. Sign in again.',
      404 => 'The coach is not deployed yet.',
      429 => 'The model is rate limited. Try again in a minute.',
      503 => detail ?? 'The coach is not configured yet.',
      _ => detail ?? 'The coach could not answer ($status).',
    };
  }

  static String? _detailOf(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'];
      return error is String && error.isNotEmpty ? error : null;
    } catch (_) {
      return null;
    }
  }

  static String _offline(Object error) =>
      'Could not reach the coach. It needs a connection — everything else in '
      'this app does not.';
}

final coachServiceProvider = Provider<CoachService>((ref) => CoachService());

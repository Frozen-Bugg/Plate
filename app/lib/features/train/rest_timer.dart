import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';

/// A rest countdown between sets.
///
/// Holds the instant rest *ends*, not a number of seconds ticking down, so the
/// clock stays honest when the screen sleeps, the app is backgrounded, or the
/// phone goes in a pocket — all of which happen during a set. Time is read
/// from the wall clock on every rebuild.
///
/// Nothing here is persisted: an unfinished rest is meaningless once you have
/// closed the app and walked out.
class RestTimerState {
  const RestTimerState({this.endsAt, this.total, this.exerciseId});

  final DateTime? endsAt;
  final Duration? total;

  /// Which exercise the rest belongs to, so its bar shows on that block only.
  final String? exerciseId;

  bool get isRunning => endsAt != null;

  Duration remaining(DateTime now) {
    final ends = endsAt;
    if (ends == null) return Duration.zero;
    final left = ends.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// 0 at the start of the rest, 1 when it is over.
  double progress(DateTime now) {
    final span = total;
    if (span == null || span.inMilliseconds == 0) return 1;
    final done = span - remaining(now);
    return (done.inMilliseconds / span.inMilliseconds).clamp(0, 1);
  }
}

class RestTimerNotifier extends Notifier<RestTimerState> {
  @override
  RestTimerState build() => const RestTimerState();

  void start(Duration rest, {required String exerciseId}) {
    state = RestTimerState(
      endsAt: DateTime.now().add(rest),
      total: rest,
      exerciseId: exerciseId,
    );
  }

  /// Adds time to a running rest, keeping the bar's proportions honest by
  /// growing the total as well.
  void extend(Duration extra) {
    final ends = state.endsAt;
    if (ends == null) return;
    state = RestTimerState(
      endsAt: ends.add(extra),
      total: (state.total ?? Duration.zero) + extra,
      exerciseId: state.exerciseId,
    );
  }

  void stop() => state = const RestTimerState();
}

final restTimerProvider =
    NotifierProvider<RestTimerNotifier, RestTimerState>(RestTimerNotifier.new);

/// How long to rest when a template says nothing. Long enough for a compound
/// set, short enough not to be silly on an isolation one.
const defaultRest = Duration(seconds: 120);

/// The countdown, shown under the exercise it belongs to.
///
/// Renders nothing unless a rest is running for [exerciseId], so adding it to
/// every exercise block costs nothing.
class RestTimerBar extends ConsumerStatefulWidget {
  const RestTimerBar({super.key, required this.exerciseId});

  final String exerciseId;

  @override
  ConsumerState<RestTimerBar> createState() => _RestTimerBarState();
}

class _RestTimerBarState extends ConsumerState<RestTimerBar> {
  Timer? _tick;
  bool _buzzed = false;

  @override
  void initState() {
    super.initState();
    // Half-second so the displayed second never lags the real one by a full
    // tick; the cost is nil since the widget only exists while resting.
    _tick = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rest = ref.watch(restTimerProvider);
    if (!rest.isRunning || rest.exerciseId != widget.exerciseId) {
      _buzzed = false;
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = PillarColors.of(context).train;
    final now = DateTime.now();
    final left = rest.remaining(now);
    final over = left == Duration.zero;

    // One buzz as it hits zero, not one per tick afterwards.
    if (over && !_buzzed) {
      _buzzed = true;
      unawaited(HapticFeedback.vibrate());
    }

    final minutes = left.inMinutes;
    final seconds = left.inSeconds % 60;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: rest.progress(now),
              minHeight: 4,
              backgroundColor: scheme.surfaceContainerHighest,
              color: over ? accent : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                over
                    ? 'Rest over'
                    : '${minutes.toString().padLeft(2, '0')}:'
                        '${seconds.toString().padLeft(2, '0')}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: over ? accent : scheme.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () =>
                    ref.read(restTimerProvider.notifier).extend(
                          const Duration(seconds: 30),
                        ),
                child: const Text('+30s'),
              ),
              TextButton(
                onPressed: () => ref.read(restTimerProvider.notifier).stop(),
                child: Text(over ? 'Done' : 'Skip'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

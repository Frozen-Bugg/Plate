import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/day.dart';
import '../../core/db/app_database.dart';
import 'recovery_repository.dart';

/// The morning check-in: four questions, five taps each, ten seconds.
///
/// Every answer is optional. A lifter who only wants to say they are wrecked
/// taps one row and saves — the engine re-weights over whatever is there, so a
/// partial answer is worth more than a skipped one.
Future<void> showCheckInSheet(BuildContext context, {String? day}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _CheckInSheet(day: day ?? dayKey()),
  );
}

class _CheckInSheet extends ConsumerStatefulWidget {
  const _CheckInSheet({required this.day});

  final String day;

  @override
  ConsumerState<_CheckInSheet> createState() => _CheckInSheetState();
}

class _CheckInSheetState extends ConsumerState<_CheckInSheet> {
  int? _sleepQuality;
  int? _soreness;
  int? _stress;
  int? _energy;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final existing =
        await ref.read(recoveryRepositoryProvider).forDay(widget.day);
    if (!mounted) return;
    setState(() {
      _loaded = true;
      if (existing case final RecoveryDay row) {
        _sleepQuality = row.sleepQuality;
        _soreness = row.soreness;
        _stress = row.stress;
        _energy = row.energy;
      }
    });
  }

  bool get _anyAnswer =>
      _sleepQuality != null ||
      _soreness != null ||
      _stress != null ||
      _energy != null;

  Future<void> _save() async {
    await ref.read(recoveryRepositoryProvider).saveCheckIn(
          sleepQuality: _sleepQuality,
          soreness: _soreness,
          stress: _stress,
          energy: _energy,
          day: widget.day,
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('This morning', style: text.headlineSmall),
            const SizedBox(height: 4),
            Text('Skip anything you would rather not answer.',
                style: text.bodySmall?.copyWith(color: muted)),
            const SizedBox(height: 20),
            _Question(
              label: 'Sleep',
              low: 'Badly',
              high: 'Well',
              value: _sleepQuality,
              onChanged: (v) => setState(() => _sleepQuality = v),
            ),
            _Question(
              label: 'Soreness',
              low: 'Fresh',
              high: 'Wrecked',
              value: _soreness,
              onChanged: (v) => setState(() => _soreness = v),
            ),
            _Question(
              label: 'Stress',
              low: 'Calm',
              high: 'Frayed',
              value: _stress,
              onChanged: (v) => setState(() => _stress = v),
            ),
            _Question(
              label: 'Energy',
              low: 'Empty',
              high: 'Full',
              value: _energy,
              onChanged: (v) => setState(() => _energy = v),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loaded && _anyAnswer ? _save : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One question: a label, five taps, and the two ends named so nobody has to
/// guess which way the scale runs.
class _Question extends StatelessWidget {
  const _Question({
    required this.label,
    required this.low,
    required this.high,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String low;
  final String high;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: text.titleSmall),
              Text('$low — $high',
                  style: text.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 1; i <= 5; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i == 5 ? 0 : 6),
                    child: _Tap(
                      number: i,
                      selected: value == i,
                      // Tapping the chosen answer again clears it, which is the
                      // only way back to "did not say" once something is set.
                      onTap: () => onChanged(value == i ? null : i),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tap extends StatelessWidget {
  const _Tap({
    required this.number,
    required this.selected,
    required this.onTap,
  });

  final int number;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 48,
          child: Center(
            child: Text(
              '$number',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

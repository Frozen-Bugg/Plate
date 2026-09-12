import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/day.dart';
import '../../core/format.dart';
import 'body_repository.dart';

/// Logs today's weigh-in. One field, one button, and the keyboard already open.
///
/// Weighing is a daily habit and a fiddly one to ask for, so this is a sheet
/// rather than a screen: it opens over whatever the lifter was doing and
/// closes as soon as the number is in.
Future<void> showLogWeightSheet(BuildContext context, {String? day}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _LogWeightSheet(day: day ?? dayKey()),
    ),
  );
}

class _LogWeightSheet extends ConsumerStatefulWidget {
  const _LogWeightSheet({required this.day});

  final String day;

  @override
  ConsumerState<_LogWeightSheet> createState() => _LogWeightSheetState();
}

class _LogWeightSheetState extends ConsumerState<_LogWeightSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  /// Starts from today's entry if there is one, otherwise the last weigh-in:
  /// the next number is nearly always within a kilo of the last, so typing it
  /// becomes a nudge rather than an entry.
  Future<void> _prefill() async {
    final repository = ref.read(bodyRepositoryProvider);
    final today = await repository.forDay(widget.day);
    final seed = today?.weightKg ?? (await repository.lastWeighIn())?.weightKg;
    if (!mounted) return;
    setState(() {
      _loaded = true;
      if (seed != null) {
        _controller.text = formatWeight(seed).replaceAll(' kg', '');
        _controller.selection =
            TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
      }
    });
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final kg = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    if (kg == null || kg < 20 || kg > 500) {
      setState(() => _error = 'Enter a weight between 20 and 500 kg');
      return;
    }
    await ref.read(bodyRepositoryProvider).logWeight(kg, day: widget.day);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final trend = ref.watch(trendWeightProvider);
    final isToday = widget.day == dayKey();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(isToday ? 'Weight today' : 'Weight on ${widget.day}',
              style: text.headlineSmall),
          const SizedBox(height: 4),
          Text(
            trend == null
                ? 'The first few days set the baseline.'
                : 'Trend ${formatWeight(trend)}. One day moves it by a tenth '
                    'of the difference, so a heavy morning is not a setback.',
            style: text.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            focusNode: _focus,
            enabled: _loaded,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            textAlign: TextAlign.center,
            style: text.displaySmall,
            decoration: InputDecoration(
              suffixText: 'kg',
              errorText: _error,
              contentPadding: const EdgeInsets.symmetric(vertical: 20),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _loaded ? _save : null, child: const Text('Save')),
        ],
      ),
    );
  }
}

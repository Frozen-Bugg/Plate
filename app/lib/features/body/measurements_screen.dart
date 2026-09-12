import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/day.dart';
import '../../core/db/app_database.dart';
import 'body_repository.dart';

/// Tape measurements for today, and what they were last time.
///
/// Monthly is plenty — a waist does not move week to week, and measuring more
/// often mostly measures where the tape sat. The previous column is there so a
/// change is visible without a chart.
class MeasurementsScreen extends ConsumerStatefulWidget {
  const MeasurementsScreen({super.key});

  @override
  ConsumerState<MeasurementsScreen> createState() => _MeasurementsScreenState();
}

class _MeasurementsScreenState extends ConsumerState<MeasurementsScreen> {
  static const _fields = [
    _Field('Neck', 'neckCm'),
    _Field('Shoulders', 'shouldersCm'),
    _Field('Chest', 'chestCm'),
    _Field('Waist', 'waistCm'),
    _Field('Hips', 'hipsCm'),
    _Field('Thigh', 'thighCm'),
    _Field('Calf', 'calfCm'),
    _Field('Arm', 'armCm'),
    _Field('Forearm', 'forearmCm'),
    _Field('Body fat', 'bodyFatPct', unit: '%'),
  ];

  final _controllers = {
    for (final field in _fields) field.key: TextEditingController(),
  };
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final today = await ref.read(bodyRepositoryProvider).forDay(dayKey());
    if (!mounted || today == null) return;
    setState(() {
      for (final field in _fields) {
        final value = field.read(today);
        if (value != null) _controllers[field.key]!.text = _trim(value);
      }
    });
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Reads every field, blank meaning "not measured" rather than zero.
  Future<void> _save() async {
    setState(() => _saving = true);
    var changes = const BodyMetricsCompanion();
    for (final field in _fields) {
      final text = _controllers[field.key]!.text.trim().replaceAll(',', '.');
      final value = text.isEmpty ? null : double.tryParse(text);
      if (text.isNotEmpty && value == null) continue;
      changes = field.write(changes, Value(value));
    }
    await ref.read(bodyRepositoryProvider).saveMeasurements(changes);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final history = ref.watch(bodyMetricsProvider).value ?? const [];
    final today = dayKey();

    return Scaffold(
      appBar: AppBar(title: const Text('Measurements')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Measure cold, before training, at the same point each time.',
            style: text.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 16),
          for (final field in _fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(flex: 3, child: Text(field.label, style: text.titleSmall)),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _controllers[field.key],
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      textAlign: TextAlign.right,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '—',
                      ),
                    ),
                  ),
                  // The unit sits outside the field on purpose: Flutter hides
                  // `suffixText` until a field has focus or content, which on a
                  // form of ten empty boxes means ten unlabelled boxes.
                  SizedBox(
                    width: 34,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(field.unit,
                          style: text.bodySmall?.copyWith(color: muted)),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      _previous(history, field, today),
                      textAlign: TextAlign.right,
                      style: text.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// The last value recorded for this field before today, as a "was ..." note.
  String _previous(List<BodyMetric> history, _Field field, String today) {
    for (final row in history.reversed) {
      if (row.measuredOn == today) continue;
      final value = field.read(row);
      if (value != null) return 'was ${_trim(value)}';
    }
    return '';
  }

  static String _trim(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}

/// One measurable thing: how to read it off a row and how to write it back.
///
/// Drift generates a named parameter per column rather than anything
/// addressable, so the two accessors are spelled out here — once — instead of
/// ten near-identical widgets each knowing its own column.
class _Field {
  const _Field(this.label, this.key, {this.unit = 'cm'});

  final String label;
  final String key;
  final String unit;

  double? read(BodyMetric row) => switch (key) {
        'neckCm' => row.neckCm,
        'shouldersCm' => row.shouldersCm,
        'chestCm' => row.chestCm,
        'waistCm' => row.waistCm,
        'hipsCm' => row.hipsCm,
        'thighCm' => row.thighCm,
        'calfCm' => row.calfCm,
        'armCm' => row.armCm,
        'forearmCm' => row.forearmCm,
        'bodyFatPct' => row.bodyFatPct,
        _ => null,
      };

  BodyMetricsCompanion write(BodyMetricsCompanion row, Value<double?> value) =>
      switch (key) {
        'neckCm' => row.copyWith(neckCm: value),
        'shouldersCm' => row.copyWith(shouldersCm: value),
        'chestCm' => row.copyWith(chestCm: value),
        'waistCm' => row.copyWith(waistCm: value),
        'hipsCm' => row.copyWith(hipsCm: value),
        'thighCm' => row.copyWith(thighCm: value),
        'calfCm' => row.copyWith(calfCm: value),
        'armCm' => row.copyWith(armCm: value),
        'forearmCm' => row.copyWith(forearmCm: value),
        'bodyFatPct' => row.copyWith(bodyFatPct: value),
        _ => row,
      };
}

import 'package:drift/drift.dart' show Value;
import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/profile/profile_repository.dart';

/// The handful of facts the engine needs before it can estimate anything.
///
/// Mifflin-St Jeor takes weight, height, age and sex. Weight comes from the
/// scale; the other three have to be asked for once. Without them the app
/// refuses to produce a calorie target rather than guessing — which is the
/// right behaviour, and also why this screen exists.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _name = TextEditingController();
  final _height = TextEditingController();
  final _birthYear = TextEditingController();
  engine.Sex? _sex;
  var _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final profile = ref.read(profileProvider).value;
    if (!mounted) return;
    setState(() {
      _loaded = true;
      if (profile case final Profile row) {
        _name.text = row.displayName ?? '';
        _height.text = row.heightCm == null ? '' : _trim(row.heightCm!);
        _birthYear.text = row.birthYear?.toString() ?? '';
        _sex = engine.Sex.fromWire(row.sex);
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _height, _birthYear]) {
      c.dispose();
    }
    super.dispose();
  }

  static String _trim(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

  Future<void> _save() async {
    final height = _height.text.trim().isEmpty
        ? null
        : double.tryParse(_height.text.trim().replaceAll(',', '.'));
    final year = _birthYear.text.trim().isEmpty
        ? null
        : int.tryParse(_birthYear.text.trim());

    // The same bounds Postgres enforces, checked here so the message is a
    // sentence rather than a rejected upload.
    if (height != null && (height < 50 || height > 272)) {
      setState(() => _error = 'Height should be between 50 and 272 cm');
      return;
    }
    final thisYear = DateTime.now().year;
    if (year != null && (year < 1900 || year > thisYear)) {
      setState(() => _error = 'Birth year should be between 1900 and $thisYear');
      return;
    }

    await ref.read(profileRepositoryProvider).update(
          ProfilesCompanion(
            displayName:
                Value(_name.text.trim().isEmpty ? null : _name.text.trim()),
            heightCm: Value(height),
            birthYear: Value(year),
            sex: Value(_sex?.wireName),
          ),
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: const Text('About you')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Used to estimate what you burn at rest, which is where calorie '
            'targets start from. Everything here is editable and nothing is '
            'sent anywhere but your own database.',
            style: text.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            enabled: _loaded,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              helperText: 'What the app calls you',
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _height,
                  enabled: _loaded,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Height',
                    suffixText: 'cm',
                  ),
                  onChanged: (_) => _clearError(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _birthYear,
                  enabled: _loaded,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Born',
                    hintText: 'YYYY',
                  ),
                  onChanged: (_) => _clearError(),
                ),
              ),
            ],
          ),
          if (_error case final message?) ...[
            const SizedBox(height: 8),
            Text(message,
                style: text.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 24),
          Text('SEX',
              style:
                  text.labelSmall?.copyWith(color: muted, letterSpacing: 1.2)),
          const SizedBox(height: 8),
          SegmentedButton<engine.Sex?>(
            segments: const [
              ButtonSegment(value: engine.Sex.female, label: Text('Female')),
              ButtonSegment(value: engine.Sex.male, label: Text('Male')),
              ButtonSegment(value: null, label: Text('Rather not')),
            ],
            selected: {_sex},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _sex = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            // Worth being straight about: it is a term in a 1990 regression,
            // not a statement about anybody, and the adaptive estimate
            // overwrites whatever it gets wrong within a fortnight of logs.
            'The equation behind the estimate was fitted with a single '
            'male/female term worth about 166 kcal. Leaving it out means no '
            'starting estimate until two weeks of food logs can measure one '
            'directly.',
            style: text.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _loaded ? _save : null,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }
}

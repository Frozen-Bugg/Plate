import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/widgets/phase_placeholder.dart';
import '../../app/widgets/tab_scaffold.dart';

class FuelScreen extends StatelessWidget {
  const FuelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return TabScaffold(
      title: 'Fuel',
      body: PhasePlaceholder(
        color: PillarColors.of(context).fuel,
        phase: 3,
        headline: 'Calorie targets that learn from your body',
        features: const [
          'Food search, barcode scanning and recipes',
          'Macro targets set by your phase: cut, maintain or bulk',
          'Adaptive TDEE from your trend weight and intake',
          'Photo and voice logging with the coach (Phase 4)',
        ],
      ),
    );
  }
}

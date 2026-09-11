import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/widgets/phase_placeholder.dart';
import '../../app/widgets/tab_scaffold.dart';

class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return TabScaffold(
      title: 'Progress',
      body: PhasePlaceholder(
        color: PillarColors.of(context).body,
        phase: 2,
        headline: 'Trends, not noise',
        features: const [
          'Bodyweight as a smoothed 7-day trend',
          'Steps, sleep and HRV from Apple Health / Health Connect',
          'Morning check-in and readiness score',
          'e1RM curves and weekly sets per muscle',
        ],
      ),
    );
  }
}

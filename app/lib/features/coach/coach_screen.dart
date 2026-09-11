import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/widgets/phase_placeholder.dart';
import '../../app/widgets/tab_scaffold.dart';

class CoachScreen extends StatelessWidget {
  const CoachScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return TabScaffold(
      title: 'Coach',
      body: PhasePlaceholder(
        color: PillarColors.of(context).coach,
        phase: 4,
        headline: 'A coach that can see every log',
        features: const [
          'Chat grounded in your training, food and recovery data',
          'Pre-workout briefs and post-workout debriefs',
          'Sunday check-in with proposals you approve',
          'Program generator and deload detective (Phase 5)',
        ],
      ),
    );
  }
}

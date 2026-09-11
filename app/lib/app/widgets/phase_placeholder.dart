import 'package:flutter/material.dart';

import 'plate_icon.dart';

/// Stands in for a tab whose features land in a later roadmap phase.
class PhasePlaceholder extends StatelessWidget {
  const PhasePlaceholder({
    super.key,
    required this.color,
    required this.phase,
    required this.headline,
    required this.features,
  });

  final Color color;
  final int phase;
  final String headline;
  final List<String> features;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      children: [
        PlateIcon(color: color, size: 28),
        const SizedBox(height: 16),
        Text(
          'ARRIVES IN PHASE $phase',
          style: text.labelSmall?.copyWith(color: muted, letterSpacing: 1.2),
        ),
        const SizedBox(height: 6),
        Text(headline, style: text.headlineSmall),
        const SizedBox(height: 16),
        for (final feature in features)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 12),
                  child: Container(width: 5, height: 5, color: color),
                ),
                Expanded(child: Text(feature, style: text.bodyLarge)),
              ],
            ),
          ),
      ],
    );
  }
}

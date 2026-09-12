import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Calories as a ring, with the three macros as smaller ones beside it.
///
/// A ring rather than a bar because the question a lifter asks mid-afternoon is
/// "how much is left", and a ring answers it without reading a number. Going
/// over is drawn rather than clamped — a day at 120% should look like a day at
/// 120%, not like a finished one.
class MacroRings extends StatelessWidget {
  const MacroRings({
    super.key,
    required this.kcal,
    required this.kcalTarget,
    required this.proteinG,
    required this.proteinTarget,
    required this.carbG,
    required this.carbTarget,
    required this.fatG,
    required this.fatTarget,
  });

  final double kcal;
  final double proteinG;
  final double carbG;
  final double fatG;

  /// Null when no target has been set yet: the ring then shows what was eaten
  /// without pretending to judge it.
  final double? kcalTarget;
  final double? proteinTarget;
  final double? carbTarget;
  final double? fatTarget;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final pillars = PillarColors.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 124,
          height: 124,
          child: _Ring(
            value: kcal,
            target: kcalTarget,
            colour: pillars.fuel,
            thickness: 11,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(kcal.round().toString(), style: text.headlineSmall),
                Text(
                  kcalTarget == null
                      ? 'kcal'
                      : 'of ${kcalTarget!.round()}',
                  style: text.labelSmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _MacroBar(
                label: 'Protein',
                grams: proteinG,
                target: proteinTarget,
                colour: pillars.train,
              ),
              const SizedBox(height: 10),
              _MacroBar(
                label: 'Carbs',
                grams: carbG,
                target: carbTarget,
                colour: pillars.move,
              ),
              const SizedBox(height: 10),
              _MacroBar(
                label: 'Fat',
                grams: fatG,
                target: fatTarget,
                colour: pillars.body,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({
    required this.value,
    required this.target,
    required this.colour,
    required this.thickness,
    required this.child,
  });

  final double value;
  final double? target;
  final Color colour;
  final double thickness;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _RingPainter(
        progress: target == null || target! <= 0 ? 0 : value / target!,
        colour: colour,
        track: Theme.of(context).colorScheme.surfaceContainerHigh,
        over: Theme.of(context).colorScheme.error,
        thickness: thickness,
      ),
      child: Center(child: child),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.colour,
    required this.track,
    required this.over,
    required this.thickness,
  });

  final double progress;
  final Color colour;
  final Color track;
  final Color over;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final centre = rect.center;
    final radius = (math.min(size.width, size.height) - thickness) / 2;
    final circle = Rect.fromCircle(center: centre, radius: radius);

    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness;
    canvas.drawCircle(centre, radius, base);

    if (progress <= 0) return;

    const start = -math.pi / 2;
    final full = math.min(progress, 1.0) * 2 * math.pi;
    canvas.drawArc(
      circle,
      start,
      full,
      false,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.round,
    );

    // The overshoot rides on top of the finished ring, so a day that went over
    // reads as over rather than as merely complete.
    if (progress > 1) {
      final extra = math.min(progress - 1, 1.0) * 2 * math.pi;
      canvas.drawArc(
        circle,
        start,
        extra,
        false,
        Paint()
          ..color = over
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness * 0.55
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.colour != colour;
}

class _MacroBar extends StatelessWidget {
  const _MacroBar({
    required this.label,
    required this.grams,
    required this.target,
    required this.colour,
  });

  final String label;
  final double grams;
  final double? target;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final progress =
        target == null || target! <= 0 ? 0.0 : (grams / target!).clamp(0.0, 1.0);
    final over = target != null && target! > 0 && grams > target!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: text.labelMedium),
            Text(
              target == null
                  ? '${grams.round()} g'
                  : '${grams.round()} / ${target!.round()} g',
              style: text.labelSmall?.copyWith(
                color: over ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: scheme.surfaceContainerHigh,
            valueColor: AlwaysStoppedAnimation(over ? scheme.error : colour),
          ),
        ),
      ],
    );
  }
}

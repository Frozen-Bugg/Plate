import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';

/// Bodyweight over time: the scale as dots, the trend as a line.
///
/// Both are drawn on purpose. The line alone would look like effortless
/// progress and hide how noisy the underlying data is; the dots alone are the
/// noise that makes people give up on a diet in week two. Together they say
/// what the Body pillar is for — the scatter is normal, the line is you.
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.points, this.height = 180});

  final List<engine.TrendPoint> points;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _TrendPainter(
          points: points,
          line: scheme.primary,
          dots: scheme.onSurfaceVariant.withValues(alpha: 0.45),
          grid: scheme.outlineVariant,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.line,
    required this.dots,
    required this.grid,
  });

  final List<engine.TrendPoint> points;
  final Color line;
  final Color dots;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final first = points.first.date;
    final span = points.last.date.difference(first).inDays;
    // A single day, or several readings on one day, has no horizontal extent;
    // draw it down the middle rather than dividing by zero.
    double x(DateTime date) => span == 0
        ? size.width / 2
        : date.difference(first).inDays / span * size.width;

    var low = double.infinity;
    var high = double.negativeInfinity;
    for (final p in points) {
      low = [low, p.weightKg, p.trendKg].reduce((a, b) => a < b ? a : b);
      high = [high, p.weightKg, p.trendKg].reduce((a, b) => a > b ? a : b);
    }
    // Pad a flat series so it sits in the middle instead of on an edge.
    if (high - low < 0.5) {
      final middle = (high + low) / 2;
      low = middle - 0.5;
      high = middle + 0.5;
    }
    final padding = (high - low) * 0.12;
    low -= padding;
    high += padding;
    double y(double kg) => size.height - (kg - low) / (high - low) * size.height;

    final rule = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final dy = size.height * i / 3;
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), rule);
    }

    final dot = Paint()..color = dots;
    for (final p in points) {
      canvas.drawCircle(Offset(x(p.date), y(p.weightKg)), 2.2, dot);
    }

    final path = Path();
    for (final (i, p) in points.indexed) {
      final offset = Offset(x(p.date), y(p.trendKg));
      i == 0 ? path.moveTo(offset.dx, offset.dy) : path.lineTo(offset.dx, offset.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final last = points.last;
    canvas.drawCircle(
      Offset(x(last.date), y(last.trendKg)),
      4,
      Paint()..color = line,
    );
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.points != points || old.line != line || old.dots != dots;
}

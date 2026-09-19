import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A visual language for the screens where the coach does something —
/// parses a sentence, drafts a recipe, suggests a meal — shared so all three
/// read as one feature rather than three forms that happen to call the same
/// API.
///
/// The rest of the app is quiet on purpose: Overload's own palette is muted,
/// pillar-coloured, built to be read at a glance mid-set. These screens are
/// the one place that quiet is wrong — they are where the app is visibly
/// *doing* something, on a network round trip, and looking exactly like every
/// other card while a model is thinking is what "boring" meant. The gradient,
/// the motion and the accent here are deliberately louder than the rest of
/// the app, deliberately confined to these screens, and never used to shift a
/// number — every figure they frame is still the same grounded value the
/// screen would have shown as plain text.

/// The accent gradient: violet into cyan. Distinct from every pillar colour
/// (train's red, fuel's green, move's amber, body's blue, coach's near-black)
/// on purpose — this marks "the model is involved" specifically, not "this is
/// the Fuel tab".
LinearGradient aiGradient(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: dark
        ? const [Color(0xFF7C3AED), Color(0xFF22D3EE)]
        : const [Color(0xFF6D28D9), Color(0xFF0891B2)],
  );
}

Color aiAccent(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFA78BFA)
    : const Color(0xFF6D28D9);

/// A header for a sheet the coach is about to answer in: gradient bar,
/// spinning-while-busy sparkle, title and a line of context underneath.
class AiSheetHeader extends StatelessWidget {
  const AiSheetHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.busy = false,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final bool busy;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
      decoration: BoxDecoration(
        gradient: aiGradient(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Row(
        children: [
          AiSparkle(spinning: busy),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: text.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: text.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// The four-point sparkle that marks "the model made this". Spins slowly
/// while [spinning] is true — thinking, not loading; there is a difference
/// between a spinner that means "wait" and one that means "this part of the
/// app has a mind of its own right now".
class AiSparkle extends StatefulWidget {
  const AiSparkle({super.key, this.spinning = false, this.size = 26});

  final bool spinning;
  final double size;

  @override
  State<AiSparkle> createState() => _AiSparkleState();
}

class _AiSparkleState extends State<AiSparkle>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final angle = widget.spinning ? _controller.value * 2 * math.pi : 0.0;
        final pulse = widget.spinning
            ? 0.75 + 0.25 * math.sin(_controller.value * 2 * math.pi)
            : 1.0;
        return Transform.rotate(
          angle: angle,
          child: Opacity(opacity: pulse, child: child),
        );
      },
      child: Icon(Icons.auto_awesome, size: widget.size, color: Colors.white),
    );
  }
}

/// The "thinking" state: a gradient bar that sweeps back and forth, plus a
/// line of what is happening. Stands in for a bare spinner everywhere the
/// coach is mid-answer — a blank circle says "wait"; this says "reading it".
class AiThinking extends StatefulWidget {
  const AiThinking({super.key, required this.label});

  final String label;

  @override
  State<AiThinking> createState() => _AiThinkingState();
}

class _AiThinkingState extends State<AiThinking>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 120,
            height: 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: _SweepPainter(
                    progress: _controller.value,
                    gradient: aiGradient(context),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(widget.label, style: text.bodyMedium?.copyWith(color: muted)),
        ],
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  _SweepPainter({required this.progress, required this.gradient});

  final double progress;
  final LinearGradient gradient;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0x22000000),
    );
    // A band that slides from left to right and wraps, rather than a
    // determinate fill — nobody can promise how long a model call takes.
    final bandWidth = size.width * 0.4;
    final x = (progress * (size.width + bandWidth)) - bandWidth;
    final rect = Rect.fromLTWH(x, 0, bandWidth, size.height);
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
  }

  @override
  bool shouldRepaint(_SweepPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// A small pill naming where a number came from — "From your foods", "AI
/// estimate", "In the fridge", "Saved recipe". Consistent shape and weight
/// everywhere it appears, because this is the one label in the whole feature
/// that is actually load-bearing: it is the difference between a measurement
/// and a guess, and it deserves to look like it matters rather than being a
/// small grey caption easy to skim past.
class AiTag extends StatelessWidget {
  const AiTag.estimate({super.key})
    : icon = Icons.auto_awesome,
      label = 'AI estimate',
      _kind = _Kind.estimate;

  const AiTag.fromShelf({super.key})
    : icon = Icons.check_circle_outline,
      label = 'From your foods',
      _kind = _Kind.shelf;

  const AiTag.custom({super.key, required this.icon, required this.label})
    : _kind = _Kind.shelf;

  final IconData icon;
  final String label;
  final _Kind _kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEstimate = _kind == _Kind.estimate;
    final Color fg;
    final Color bg;
    if (isEstimate) {
      fg = aiAccent(context);
      bg = aiAccent(context).withValues(alpha: 0.12);
    } else {
      fg = theme.colorScheme.onSurfaceVariant;
      bg = theme.colorScheme.surfaceContainerHighest;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

enum _Kind { estimate, shelf }

/// Fades and rises a result into place, staggered by [index]. Applied to
/// every row a parse/draft/suggestion produces, so an answer arrives the way
/// a chat message does — appearing, not just being suddenly present the
/// instant the frame redraws.
class AiReveal extends StatelessWidget {
  const AiReveal({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 320 + index * 60),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 12),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

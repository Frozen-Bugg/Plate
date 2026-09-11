import 'package:flutter/material.dart';

/// A bumper plate seen face-on: the pillar marker used across the app.
class PlateIcon extends StatelessWidget {
  const PlateIcon({super.key, required this.color, this.size = 20});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Container(
        width: size * 0.32,
        height: size * 0.32,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

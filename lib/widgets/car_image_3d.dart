import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Car image with the exact 3D floating shadow from the Shopify web widget:
///
/// ```css
/// filter: drop-shadow(0 3px 2px #000) drop-shadow(0 9px 12px #000);
/// ```
///
/// CSS `drop-shadow` respects the PNG alpha channel (unlike Flutter's
/// [BoxShadow] which shadows the rectangular bounding box). We replicate it
/// by stacking two PNG-aware copies under the real image: each copy is
/// tinted solid black with [BlendMode.srcIn], offset down, then blurred.
///
/// Use this everywhere a ride card renders a vehicle PNG so every card
/// feels physically lit the same way.
class CarImage3D extends StatelessWidget {
  final String assetPath;
  final int? cacheWidth;
  final bool dimmed;
  final Duration dimDuration;
  final Widget? fallback;

  const CarImage3D({
    super.key,
    required this.assetPath,
    this.cacheWidth,
    this.dimmed = false,
    this.dimDuration = const Duration(milliseconds: 200),
    this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final car = Image.asset(
      assetPath,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      isAntiAlias: true,
      cacheWidth: cacheWidth,
      errorBuilder: (_, __, ___) =>
          fallback ??
          Icon(
            Icons.directions_car_rounded,
            size: 36,
            color: Colors.white.withValues(alpha: 0.5),
          ),
    );

    Widget shadow({required double dy, required double blur, required double alpha}) {
      return Positioned.fill(
        child: IgnorePointer(
          child: Transform.translate(
            offset: Offset(0, dy),
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: alpha),
                  BlendMode.srcIn,
                ),
                child: car,
              ),
            ),
          ),
        ),
      );
    }

    return AnimatedOpacity(
      opacity: dimmed ? 0.75 : 1.0,
      duration: dimDuration,
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          // drop-shadow(0 9px 12px #000) — ambient floating glow.
          shadow(dy: 9, blur: 12, alpha: 0.55),
          // drop-shadow(0 3px 2px #000) — tight contact shadow.
          shadow(dy: 3, blur: 2, alpha: 0.85),
          car,
        ],
      ),
    );
  }
}

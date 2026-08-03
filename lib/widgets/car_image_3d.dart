import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Car image with silhouette drop shadows for dark vehicle cards.
///
/// The shadow is the render's own alpha mask, tinted black and blurred —
/// it covers exactly the car's silhouette, never a plate or a ground
/// blob behind it.
///
/// Plus an optional gold glow when selected.
class CarImage3D extends StatelessWidget {
  final String assetPath;
  final int? cacheWidth;
  final bool dimmed;
  final Duration dimDuration;
  final Widget? fallback;
  final bool selected;
  final AlignmentGeometry alignment;

  const CarImage3D({
    super.key,
    required this.assetPath,
    this.cacheWidth,
    this.dimmed = false,
    this.dimDuration = const Duration(milliseconds: 200),
    this.fallback,
    this.selected = false,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    // Shared image provider so all shadow/glow layers reuse the same decoded image
    final imageProvider = ResizeImage.resizeIfNeeded(
      cacheWidth,
      null,
      AssetImage(assetPath),
    );

    Widget carImage({ColorFilter? colorFilter}) {
      return Image(
        image: imageProvider,
        fit: BoxFit.contain,
        alignment: alignment,
        filterQuality: FilterQuality.high,
        isAntiAlias: true,
        errorBuilder: (_, __, ___) =>
            fallback ??
            Icon(
              Icons.directions_car_rounded,
              size: 36,
              color: Colors.white.withValues(alpha: 0.5),
            ),
        color: colorFilter != null ? Colors.white : null,
        colorBlendMode: colorFilter != null ? BlendMode.srcIn : null,
      );
    }

    // Silhouette drop shadow: the car's own alpha mask, tinted black and
    // blurred — the shadow covers exactly the car's silhouette, nothing
    // else (no plate, no ellipse).
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
                child: carImage(),
              ),
            ),
          ),
        ),
      );
    }

    // Gold glow when selected
    Widget goldGlow() {
      if (!selected) return const SizedBox.shrink();
      return Positioned.fill(
        child: IgnorePointer(
          child: Transform.translate(
            offset: const Offset(0, 4),
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Color(0x40E8C547), // Gold with alpha
                  BlendMode.srcIn,
                ),
                child: carImage(),
              ),
            ),
          ),
        ),
      );
    }

    return AnimatedOpacity(
      opacity: dimmed ? 0.70 : 1.0,
      duration: dimDuration,
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          // Silhouette shadows only — they follow the car's alpha mask,
          // so the shadow never reads as a plate behind the render.
          shadow(dy: 9, blur: 10, alpha: 0.50),
          shadow(dy: 3, blur: 3, alpha: 0.75),
          // Gold glow when selected
          goldGlow(),
          // Actual car image on top
          carImage(),
        ],
      ),
    );
  }
}

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

    // Ground shadow: the car's own silhouette CAST ON THE FLOOR — the
    // alpha mask tinted black, squashed vertically against the wheels and
    // blurred. It keeps the car's actual form (never a plate or an
    // ellipse) but reads as the shape on the ground under it, softly
    // diffused (user spec, 2026-08-04).
    Widget shadow({required double dy, required double blur, required double alpha}) {
      return Positioned.fill(
        child: IgnorePointer(
          child: Transform(
            alignment: Alignment.bottomCenter,
            transform: Matrix4.identity()
              ..translate(0.0, dy)
              // Flatten to 38% height, pinned at the wheels; a touch wider
              // so the ground spread peeks past the body like a real cast.
              ..scale(1.06, 0.38),
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
          // ONE soft ground shadow — the car's form on the floor, diffused,
          // never "marked". The old pair included a barely-blurred
          // 75%-black layer that read as a hard dark stamp under the car
          // (user report, 2026-08-04); the squashed silhouette keeps the
          // shape, the harshness goes.
          shadow(dy: 7, blur: 7, alpha: 0.38),
          // Gold glow when selected
          goldGlow(),
          // Actual car image on top
          carImage(),
        ],
      ),
    );
  }
}

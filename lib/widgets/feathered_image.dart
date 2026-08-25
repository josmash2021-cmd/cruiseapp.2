import 'package:flutter/material.dart';

/// Image with feathered (faded) edges all around — the borders dissolve
/// into the page background instead of ending in a hard crop. Used by the
/// rider/driver registration and onboarding heroes (user spec 2026-08-25).
///
/// Implemented as a radial ShaderMask: fully opaque in the center, fading
/// to transparent toward every edge. No asset editing required.
class FeatheredImage extends StatelessWidget {
  final String asset;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// How far from the center the fade starts (0..1). Higher = harder edge.
  final double fadeStart;

  /// Optional corner rounding applied BEFORE the feather.
  final BorderRadius? borderRadius;

  /// Passed through to [Image.asset] (e.g. an icon fallback when the
  /// bundled asset is missing).
  final ImageErrorWidgetBuilder? errorBuilder;

  const FeatheredImage(
    this.asset, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.fadeStart = 0.55,
    this.borderRadius,
    this.errorBuilder,
  });

  @override
  Widget build(BuildContext context) {
    Widget img = Image.asset(
      asset,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: errorBuilder,
    );
    if (borderRadius != null) {
      img = ClipRRect(borderRadius: borderRadius!, child: img);
    }
    return ShaderMask(
      shaderCallback: (rect) => RadialGradient(
        // Elliptical reach so the fade also covers left/right edges.
        radius: 1.05,
        center: Alignment.center,
        colors: const [Colors.white, Colors.white, Colors.transparent],
        stops: [0.0, fadeStart, 1.0],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: img,
    );
  }
}

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Frosted grey glass for the driver's map chrome (owner spec 2026-10-30:
/// "que sea transparente pero blurry, manteniendo que se vea gris") — the
/// online/offline sheet, the round map buttons, the earnings pill, the menu.
///
/// The neumorphic system ([neuBox]) stays for full pages; this is for what
/// floats OVER the map, where an opaque grey slab hides the one thing the
/// driver is looking at. Constants are top-level (project rule #16: part
/// files may only use top-level constants inside `const` expressions).
///
/// iOS caveat, measured in the engine (FlutterPlatformViewsController.mm):
/// a blur over the native Mapbox view is applied by a UIVisualEffectView
/// framed to the filter's bounding RECTANGLE — it does not follow a
/// ClipOval/ClipRRect. Small round controls therefore use a light blur
/// ([kGlassChipBlur]) so the square corners of the blurred patch stay
/// invisible; the sheet, whose corners are a tiny share of its area,
/// carries the heavy one ([kGlassSheetBlur]). Android hosts the map as a
/// texture (virtual display), where the clip is exact.
///
/// A [BackdropFilter] inside an Opacity < 1, an ImageFiltered or any other
/// save-layer only sees that layer, not the map — keep glass out of
/// permanent layers (fade-in transitions are fine; at rest they drop out).
const glassTint = Color(0x8F1E1E26); // grey glass, ~56 %
const glassSheetTint = Color(0xA31A1A21); // a touch denser behind text, ~64 %
const glassTintLight = Color(0xB3FFFFFF);
const glassEdge = Color(0x24FFFFFF); // hairline, white 14 %
const kGlassSheetBlur = 24.0;
const kGlassChipBlur = 6.0;

/// Cards and wells INSIDE a glass surface — the drop-in for [neuBox] there.
/// An opaque neu card on glass reads as a grey slab again; this one is a
/// faint lift (raised) or a faint dip (pressed) of the same glass.
BoxDecoration glassInnerBox({
  double radius = 24,
  bool pressed = false,
  Color? borderColor,
  double borderWidth = 1,
}) =>
    BoxDecoration(
      color: pressed
          ? Colors.black.withValues(alpha: 0.22)
          : Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: borderColor ??
            Colors.white.withValues(alpha: pressed ? 0.04 : 0.08),
        width: borderWidth,
      ),
    );

/// A frosted surface: clip → backdrop blur → translucent grey + hairline.
///
/// Anything that must poke OUTSIDE the shape (a count badge) goes in a
/// Stack next to it, never inside — the clip would cut it.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.circle = false,
    this.borderRadius = BorderRadius.zero,
    this.blur = kGlassChipBlur,
    this.tint,
    this.borderColor,
    this.borderWidth = 1,
    this.border,
    this.width,
    this.height,
    this.padding,
  });

  final Widget child;
  final bool circle;
  final BorderRadius borderRadius;
  final double blur;
  final Color? tint;
  final Color? borderColor;
  final double borderWidth;

  /// Overrides [borderColor]/[borderWidth] (e.g. a top-only hairline).
  final BoxBorder? border;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget body = DecoratedBox(
      decoration: BoxDecoration(
        color: tint ?? (isDark ? glassTint : glassTintLight),
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : borderRadius,
        border: border ??
            Border.all(color: borderColor ?? glassEdge, width: borderWidth),
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
    if (width != null || height != null) {
      body = SizedBox(width: width, height: height, child: body);
    }
    final frosted = BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: body,
    );
    return circle
        ? ClipOval(child: frosted)
        : ClipRRect(borderRadius: borderRadius, child: frosted);
  }
}

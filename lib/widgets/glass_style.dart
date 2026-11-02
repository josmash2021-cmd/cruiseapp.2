import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Frosted grey glass for the driver's map chrome (owner spec 2026-10-30:
/// "que sea transparente pero blurry, manteniendo que se vea gris") — the
/// online/offline sheet and the Help sheet. The round map buttons and the
/// earnings pill are [MapChipSurface]: translucent, NOT blurred (see below).
///
/// The neumorphic system ([neuBox]) stays for full pages; this is for what
/// floats OVER the map, where an opaque grey slab hides the one thing the
/// driver is looking at. Constants are top-level (project rule #16: part
/// files may only use top-level constants inside `const` expressions).
///
/// iOS caveat, measured in the engine (FlutterPlatformViewsController.mm):
/// a blur over the native Mapbox view is applied by a UIVisualEffectView
/// framed to the filter's bounding RECTANGLE — it does not follow a
/// ClipOval/ClipRRect. On a round control that is a blurred SQUARE around
/// the button (owner report 2026-10-31, the earnings pill: "tiene como un
/// cuadrado con esquinas"), so round controls carry no blur at all; only
/// the sheet, whose corners are a tiny share of its area, is frosted.
/// Android hosts the map as a texture (virtual display), where the clip is
/// exact — the controls skip the blur there too, so both look the same.
///
/// A [BackdropFilter] inside an Opacity < 1, an ImageFiltered or any other
/// save-layer only sees that layer, not the map — keep glass out of
/// permanent layers (fade-in transitions are fine; at rest they drop out).
const glassTint = Color(0x8F1E1E26); // grey glass, ~56 %
// Dark smoked glass (owner 2026-11-02, on the phone: "se ve el contenido
// que está debajo, no debe verse el contenido que hay detrás… hazlo
// borroso y un poquito oscuro"). The frost softens the map, but what the
// app draws OVER the map — the arrow, the round buttons, the earnings
// pill — still read through the 64 % / 82 % tints (the "$0.00" was
// legible under the banner). Only the tint can hide those, so every glass
// that floats over the map wears it: the sheets, the banner, the nav panel
// and the nav intro.
const glassSheetTint = Color(0xE61A1A21); // ~90 %
const glassTintLight = Color(0xB3FFFFFF);
// The OPEN sheet (owner 2026-10-31: "estilo vidrio borroso, pero que no se
// vea los botones del mapa ni la flecha detrás") a step denser still.
const glassSheetOpenTint = Color(0xF01A1A21); // ~94 %
const kGlassSheetBlurOpen = 44.0;
// Map controls: translucent grey with depth instead of blur.
const mapChipTint = Color(0xB81E1E26); // ~72 %
const glassEdge = Color(0x24FFFFFF); // hairline, white 14 %
const kGlassSheetBlur = 44.0; // the open sheet's frost, resting too

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
    this.blur = kGlassSheetBlur,
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


/// A control that floats over the map WITHOUT blurring it (owner spec
/// 2026-10-31: "quita el desenfoque, solo debe estar el botón, con una leve
/// sombra para que se vea 3D") — menu, notifications, recentre, help, zone
/// compass, the GO-side calendar, the earnings pill. Translucent grey, a
/// faint top light, a hairline rim and a soft drop shadow: the button
/// alone, no blurred patch around it (see the iOS caveat at the top).
class MapChipSurface extends StatelessWidget {
  const MapChipSurface({
    super.key,
    required this.child,
    this.circle = false,
    this.borderRadius = BorderRadius.zero,
    this.tint,
    this.borderColor,
    this.borderWidth = 1,
    this.width,
    this.height,
    this.padding,
  });

  final Widget child;
  final bool circle;
  final BorderRadius borderRadius;
  final Color? tint;
  final Color? borderColor;
  final double borderWidth;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = tint ?? (isDark ? mapChipTint : glassTintLight);
    return Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : borderRadius,
        // Lit from above: a touch lighter at the top edge.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(base, Colors.white, 0.07)!, base],
        ),
        border: Border.all(color: borderColor ?? glassEdge, width: borderWidth),
        boxShadow: const [
          BoxShadow(
            color: Color(0x5C000000), // black 36 %
            blurRadius: 10,
            offset: Offset(0, 4),
            spreadRadius: -1,
          ),
        ],
      ),
      child: child,
    );
  }
}

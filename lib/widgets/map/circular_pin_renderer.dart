import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Unified circular map pin renderer with consistent styling across all screens.
/// Creates clean circular pins with dark/navy background, white icons, and 3D shadow.
/// 
/// This replaces the old gold teardrop pins with a modern, professional circular design.

/// Pin icon types for different location contexts
enum CircularPinIcon { 
  dot,        // Simple dot (pickup location)
  flag,       // Flag marker (dropoff location)
  person,     // Person icon (rider location)
  home,       // House icon (home address)
  store,      // Store/shop icon (commercial location)
  airplane,   // Airplane icon (airport)
}

/// Detects the appropriate icon from an address label
CircularPinIcon detectCircularPinIcon(String label) {
  final l = label.toLowerCase();
  
  // Airport detection
  if (l.contains('airport') ||
      l.contains('terminal') ||
      RegExp(
        r'\b(mia|fll|jfk|lax|ord|atl|sfo|dfw|ewr|bos|iah|dca|phl|msp|dtw|sea|den|las|mco|clt)\b',
      ).hasMatch(l)) {
    return CircularPinIcon.airplane;
  }
  
  // Commercial location detection
  if (l.contains('store') ||
      l.contains('shop') ||
      l.contains('mall') ||
      l.contains('plaza') ||
      l.contains('market') ||
      l.contains('center') ||
      l.contains('restaurant') ||
      l.contains('hotel') ||
      l.contains('bar') ||
      l.contains('café') ||
      l.contains('cafe') ||
      l.contains('gym') ||
      l.contains('salon') ||
      l.contains('office') ||
      l.contains('hospital') ||
      l.contains('clinic') ||
      l.contains('bank') ||
      l.contains('pharmacy')) {
    return CircularPinIcon.store;
  }
  
  // Residential address detection (street number + street type)
  if (RegExp(r'^\d+\s').hasMatch(l) &&
      RegExp(
        r'\b(st|ave|rd|dr|ln|ct|blvd|way|pkwy|pl|cir|ter|loop)\b',
      ).hasMatch(l)) {
    return CircularPinIcon.home;
  }
  
  return CircularPinIcon.flag;
}

/// Navy/dark background color for pins (matching ride options screen style)
const _pinBackgroundDark = Color(0xFF1A1F2E);
const _pinBackgroundNavy = Color(0xFF0A0C12);

/// Cache for rendered pin bytes to avoid re-rendering
final Map<String, Uint8List> _circularPinCache = {};

/// Renders a circular map pin as PNG bytes, matching the design from the ride options screen.
/// 
/// [icon] — icon type to render inside the pin
/// [isPickup] — true for pickup (green accent), false for dropoff (white accent)
/// [radius] — radius of the circular pin (default 32)
/// 
/// Results are cached by (icon, isPickup, radius) key for performance.
Future<Uint8List> renderCircularPinBytes({
  CircularPinIcon icon = CircularPinIcon.dot,
  bool isPickup = true,
  double radius = 32.0,
}) async {
  final key = '${icon.name}_${isPickup}_$radius';
  if (_circularPinCache.containsKey(key)) return _circularPinCache[key]!;

  final size = (radius * 2 + 16).roundToDouble();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size, size));
  final cx = size / 2;
  final cy = size / 2;

  // ── 1. DROP SHADOW (subtle 3D effect) ──
  canvas.drawCircle(
    Offset(cx, cy + 3),
    radius + 1,
    Paint()
      ..color = Colors.black.withValues(alpha: 0.40)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
  );

  // ── 2. OUTER RING (white border for contrast) ──
  canvas.drawCircle(
    Offset(cx, cy),
    radius,
    Paint()..color = Colors.white,
  );

  // ── 3. INNER CIRCLE (dark navy background) ──
  final bgColor = isPickup ? _pinBackgroundDark : _pinBackgroundNavy;
  canvas.drawCircle(
    Offset(cx, cy),
    radius - 3,
    Paint()..color = bgColor,
  );

  // ── 4. SUBTLE GRADIENT HIGHLIGHT (3D gloss) ──
  final gradientPaint = Paint()
    ..shader = RadialGradient(
      center: const Alignment(-0.3, -0.4),
      radius: 0.8,
      colors: [
        Colors.white.withValues(alpha: 0.15),
        Colors.transparent,
      ],
    ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: radius - 3));
  canvas.drawCircle(Offset(cx, cy), radius - 3, gradientPaint);

  // ── 5. ICON (white, centered) ──
  _drawIcon(canvas, icon, cx, cy, radius, isPickup);

  // ── 6. ENCODE TO PNG ──
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.toInt(), size.toInt());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) return Uint8List(0);
  
  final bytes = byteData.buffer.asUint8List();
  _circularPinCache[key] = bytes;
  return bytes;
}

/// Draws a white icon inside the circular pin
void _drawIcon(Canvas canvas, CircularPinIcon icon, double cx, double cy, double radius, bool isPickup) {
  final paint = Paint()
    ..color = Colors.white
    ..style = PaintingStyle.fill;
  
  final strokePaint = Paint()
    ..color = Colors.white
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  final iconSize = radius * 0.48;

  switch (icon) {
    case CircularPinIcon.dot:
      // Simple solid dot (for pickup location)
      canvas.drawCircle(Offset(cx, cy), radius * 0.25, paint);
      break;

    case CircularPinIcon.flag:
      // Flag marker (for dropoff location)
      final flagPath = Path()
        ..moveTo(cx - iconSize * 0.3, cy - iconSize * 0.5)
        ..lineTo(cx - iconSize * 0.3, cy + iconSize * 0.6)
        ..moveTo(cx - iconSize * 0.3, cy - iconSize * 0.5)
        ..lineTo(cx + iconSize * 0.4, cy - iconSize * 0.2)
        ..lineTo(cx - iconSize * 0.3, cy + iconSize * 0.1)
        ..close();
      canvas.drawPath(flagPath, strokePaint);
      canvas.drawPath(
        Path()
          ..moveTo(cx - iconSize * 0.3, cy - iconSize * 0.5)
          ..lineTo(cx + iconSize * 0.4, cy - iconSize * 0.2)
          ..lineTo(cx - iconSize * 0.3, cy + iconSize * 0.1)
          ..close(),
        paint,
      );
      break;

    case CircularPinIcon.person:
      // Person icon (head + body)
      // Head
      canvas.drawCircle(
        Offset(cx, cy - iconSize * 0.25),
        iconSize * 0.22,
        paint,
      );
      // Body (rounded rectangle)
      final bodyPath = Path()
        ..moveTo(cx - iconSize * 0.35, cy + iconSize * 0.05)
        ..lineTo(cx - iconSize * 0.35, cy + iconSize * 0.5)
        ..lineTo(cx + iconSize * 0.35, cy + iconSize * 0.5)
        ..lineTo(cx + iconSize * 0.35, cy + iconSize * 0.05)
        ..arcToPoint(
          Offset(cx - iconSize * 0.35, cy + iconSize * 0.05),
          radius: Radius.circular(iconSize * 0.35),
          clockwise: false,
        )
        ..close();
      canvas.drawPath(bodyPath, paint);
      break;

    case CircularPinIcon.home:
      // House icon (roof + base)
      final homePath = Path()
        // Roof
        ..moveTo(cx, cy - iconSize * 0.5)
        ..lineTo(cx - iconSize * 0.45, cy)
        ..lineTo(cx + iconSize * 0.45, cy)
        ..close()
        // Base
        ..moveTo(cx - iconSize * 0.35, cy)
        ..lineTo(cx - iconSize * 0.35, cy + iconSize * 0.5)
        ..lineTo(cx + iconSize * 0.35, cy + iconSize * 0.5)
        ..lineTo(cx + iconSize * 0.35, cy)
        ..close();
      canvas.drawPath(homePath, paint);
      // Door
      final bgColor = isPickup ? _pinBackgroundDark : _pinBackgroundNavy;
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(cx, cy + iconSize * 0.25),
          width: iconSize * 0.28,
          height: iconSize * 0.35,
        ),
        Paint()..color = bgColor,
      );
      break;

    case CircularPinIcon.store:
      // Store icon (storefront with awning)
      final storePath = Path()
        // Awning
        ..moveTo(cx - iconSize * 0.5, cy - iconSize * 0.3)
        ..quadraticBezierTo(
          cx, cy - iconSize * 0.4,
          cx + iconSize * 0.5, cy - iconSize * 0.3,
        )
        ..lineTo(cx + iconSize * 0.4, cy - iconSize * 0.1)
        ..lineTo(cx - iconSize * 0.4, cy - iconSize * 0.1)
        ..close()
        // Building
        ..moveTo(cx - iconSize * 0.4, cy - iconSize * 0.1)
        ..lineTo(cx - iconSize * 0.4, cy + iconSize * 0.5)
        ..lineTo(cx + iconSize * 0.4, cy + iconSize * 0.5)
        ..lineTo(cx + iconSize * 0.4, cy - iconSize * 0.1)
        ..close();
      canvas.drawPath(storePath, paint);
      // Door
      final bgColorStore = isPickup ? _pinBackgroundDark : _pinBackgroundNavy;
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(cx, cy + iconSize * 0.25),
          width: iconSize * 0.35,
          height: iconSize * 0.4,
        ),
        Paint()..color = bgColorStore,
      );
      break;

    case CircularPinIcon.airplane:
      // Airplane icon (simplified side view)
      final planePath = Path()
        // Fuselage
        ..moveTo(cx - iconSize * 0.5, cy)
        ..lineTo(cx + iconSize * 0.45, cy)
        // Tail
        ..moveTo(cx + iconSize * 0.35, cy)
        ..lineTo(cx + iconSize * 0.45, cy - iconSize * 0.3)
        // Wings
        ..moveTo(cx - iconSize * 0.1, cy)
        ..lineTo(cx - iconSize * 0.3, cy - iconSize * 0.35)
        ..moveTo(cx - iconSize * 0.1, cy)
        ..lineTo(cx - iconSize * 0.3, cy + iconSize * 0.35);
      canvas.drawPath(planePath, strokePaint);
      break;
  }
}

/// Widget wrapper for the circular pin (for use in Stack overlays)
class CircularMapPin extends StatelessWidget {
  final CircularPinIcon icon;
  final bool isPickup;
  final double size;

  const CircularMapPin({
    super.key,
    this.icon = CircularPinIcon.dot,
    this.isPickup = true,
    this.size = 64,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: renderCircularPinBytes(
        icon: icon,
        isPickup: isPickup,
        radius: size / 2,
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return SizedBox(width: size, height: size);
        }
        return Image.memory(
          snapshot.data!,
          width: size,
          height: size,
          fit: BoxFit.contain,
        );
      },
    );
  }
}

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The two markers that sit at the ends of an offer's route preview.
///
/// They match the offer card exactly: a gold disc where the card shows its
/// gold dot, a white disc where the card shows its white one. A map that
/// labels the pickup with a different shape than the card beside it makes
/// the driver work out which is which twice. (The dropoff used to be a
/// square; a circle reads calmer next to the gold disc and the driver
/// asked for it.)
///
/// Both are drawn centre-anchored, so the marker sits *on* the coordinate
/// rather than pointing down at it from above — these are positions, not
/// teardrop pins.

const _gold = Color(0xFFE8C547);

/// Raster density for the offer-preview markers: the same artwork at 3×
/// the pixels. The badge taught this lesson first (GoldLocationDot
/// .rasterScale): Mapbox draws a 55 px bitmap at iconSize 1.0 as 55
/// *logical* px, which on a 3× Android phone is a 3× upscale — the fuzzy
/// ring in the offer screenshot. Render at this scale and divide the
/// iconSize by it: same on-screen size, ~1:1 pixels.
const double kEndpointRasterScale = 3.0;

/// A raised gold bead: black gradient shadow, rim, and a glossy body.
/// 26, down from 30 (44 originally) — small enough to sit under the route
/// line's importance, big enough to find at a glance.
Future<Uint8List> renderPickupDotBytes({double size = 26, double rasterScale = 1.0}) =>
    _render(size, fill: _gold, rasterScale: rasterScale);

/// A white bead, same size and treatment as the pickup one.
Future<Uint8List> renderDropoffCircleBytes({double size = 26, double rasterScale = 1.0}) =>
    _render(size, fill: Colors.white, rasterScale: rasterScale);

/// Driver offer map only: the pickup is a hollow ring — no fill, just the
/// band. (The rider's receipt uses the solid beads above; the driver asked
/// for the inverted pair on this page.)
Future<Uint8List> renderPickupRingBytes({double size = 26, double rasterScale = 1.0}) =>
    _renderRing(size, color: _gold, innerDot: false, rasterScale: rasterScale);

/// Driver offer map only: the dropoff is a ring with a solid dot inside.
Future<Uint8List> renderDropoffRingDotBytes({double size = 26, double rasterScale = 1.0}) =>
    _renderRing(size, color: Colors.white, innerDot: true, rasterScale: rasterScale);

Future<Uint8List> _renderRing(
  double size, {
  required Color color,
  required bool innerDot,
  double rasterScale = 1.0,
}) async {
  final canvasSize = size * 2.1;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // Logical drawing below, physical pixels above: the scale makes every
  // stroke, blur and radius land at [rasterScale]× the resolution with no
  // change to the artwork itself.
  canvas.scale(rasterScale);
  final centre = Offset(canvasSize / 2, canvasSize / 2);
  final r = size / 2;
  final stroke = size * 0.22;

  // Same soft ground shadow the beads cast, so ring and bead read as the
  // same family sitting on the road.
  canvas.drawOval(
    Rect.fromCenter(
      center: centre.translate(0, r * 0.35),
      width: size * 1.05,
      height: size * 0.85,
    ),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
  );

  // The ring itself, with a dark hairline on both edges so the band keeps
  // its shape over light streets.
  final ringRadius = r - stroke / 2;
  canvas.drawCircle(
    centre,
    ringRadius,
    Paint()
      ..color = const Color(0xFF0B0B0F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke + 1.6,
  );
  canvas.drawCircle(
    centre,
    ringRadius,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke,
  );

  // Dropoff only: the solid dot the ring carries inside.
  if (innerDot) {
    canvas.drawCircle(
      centre,
      size * 0.16,
      Paint()..color = color,
    );
  }

  final img = await recorder.endRecording().toImage(
        (canvasSize * rasterScale).ceil(),
        (canvasSize * rasterScale).ceil(),
      );
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

Future<Uint8List> _render(
  double size, {
  required Color fill,
  double rasterScale = 1.0,
}) async {
  // The canvas is bigger than the marker so the shadow has room to fall;
  // without it the blur is clipped square at the bitmap's edge.
  final canvasSize = size * 2.1;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(rasterScale);
  final centre = Offset(canvasSize / 2, canvasSize / 2);
  final r = size / 2;

  // 3D depth, three parts: a soft black shadow the bead casts down onto the
  // road, a dark rim for the edge, and a body with a vertical gradient —
  // light on top, full colour in the middle, dark at the bottom — plus a
  // small gloss. Flat shapes on a dark map read as stickers; this reads as
  // something sitting ON the road.
  canvas.drawOval(
    Rect.fromCenter(
      center: centre.translate(0, r * 0.35),
      width: size * 1.05,
      height: size * 0.85,
    ),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
  );

  canvas.drawCircle(
    centre,
    r + 1.6,
    Paint()..color = const Color(0xFF0B0B0F),
  );

  canvas.drawCircle(
    centre,
    r,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(centre.dx, centre.dy - r),
        Offset(centre.dx, centre.dy + r),
        [
          Color.lerp(fill, Colors.white, 0.45)!,
          fill,
          Color.lerp(fill, Colors.black, 0.35)!,
        ],
        const [0.0, 0.45, 1.0],
      ),
  );

  // Gloss on the upper half — the light source the gradient implies.
  canvas.drawOval(
    Rect.fromCenter(
      center: centre.translate(0, -r * 0.38),
      width: size * 0.58,
      height: size * 0.34,
    ),
    Paint()
      ..color = Colors.white.withValues(alpha: 0.40)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
  );

  final img = await recorder.endRecording().toImage(
        (canvasSize * rasterScale).ceil(),
        (canvasSize * rasterScale).ceil(),
      );
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

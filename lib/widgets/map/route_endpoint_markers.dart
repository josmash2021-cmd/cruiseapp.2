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

/// A raised gold bead: black gradient shadow, rim, and a glossy body.
/// 26, down from 30 (44 originally) — small enough to sit under the route
/// line's importance, big enough to find at a glance.
Future<Uint8List> renderPickupDotBytes({double size = 26}) =>
    _render(size, fill: _gold);

/// A white bead, same size and treatment as the pickup one.
Future<Uint8List> renderDropoffCircleBytes({double size = 26}) =>
    _render(size, fill: Colors.white);

Future<Uint8List> _render(
  double size, {
  required Color fill,
}) async {
  // The canvas is bigger than the marker so the shadow has room to fall;
  // without it the blur is clipped square at the bitmap's edge.
  final canvasSize = size * 2.1;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
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
        canvasSize.ceil(),
        canvasSize.ceil(),
      );
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}
